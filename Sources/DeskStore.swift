import SwiftUI
import Security
import AppKit
import UniformTypeIdentifiers

enum TokenVault {
    private static let service="ai.anodhas.telegram-order-desk"
    private static let account="bot-token"
    static func query()->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] }
    static func read() throws->String? {
        var q=query();q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var value:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&value)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=value as? Data,let text=String(data:data,encoding:.utf8) else{throw VaultError.unavailable}
        return text
    }
    static func save(_ token:String)throws {
        let value=[kSecValueData as String:Data(token.utf8)]
        let status=SecItemUpdate(query() as CFDictionary,value as CFDictionary)
        if status==errSecItemNotFound {
            var q=query();q[kSecValueData as String]=Data(token.utf8)
            guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw VaultError.unavailable}
        } else if status != errSecSuccess {throw VaultError.unavailable}
    }
    static func remove()throws {let s=SecItemDelete(query() as CFDictionary);guard s==errSecSuccess || s==errSecItemNotFound else{throw VaultError.unavailable}}
    enum VaultError:Error {case unavailable}
}

@MainActor
final class DeskStore:ObservableObject {
    @Published private(set) var snapshot=DeskSnapshot()
    @Published private(set) var connection="Не подключён"
    @Published private(set) var bot:TGBot?
    @Published private(set) var connected=false
    @Published private(set) var connecting=false
    @Published private(set) var storageBlocked=false
    @Published var errorText=""
    @Published var selected:UUID?
    @Published var summaryDate=Date()
    private let disk:DiskStore
    private var api:BotAPI?
    private var polling:Task<Void,Never>?
    private var runID=UUID()

    init() {
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TelegramOrderDesk",isDirectory:true)
        disk=DiskStore(url:folder.appendingPathComponent("orders-v1.json"))
        do{snapshot=try disk.load()}catch{storageBlocked=true;errorText="Сохранённые заказы не удалось прочитать. Данные не перезаписаны; получение заблокировано."}
    }
    var orders:[Order]{snapshot.orders.sorted{$0.receivedAt>$1.receivedAt}}
    var selectedOrder:Order?{snapshot.orders.first{$0.id==selected}}
    var summary:[SummaryLine]{Summary.lines(snapshot.orders,day:Day.string(summaryDate))}
    @discardableResult
    func commit(_ candidate:DeskSnapshot)->Bool {
        guard !storageBlocked else{return false}
        do{try disk.save(candidate);snapshot=candidate;return true}
        catch{storageBlocked=true;disconnect();errorText="Не удалось сохранить заказы. Получение остановлено; прежние данные сохранены.";return false}
    }
    func update(_ id:UUID,_ edit:(inout Order)->Void) {
        var candidate=snapshot
        guard let index=candidate.orders.firstIndex(where:{$0.id==id}) else{return}
        edit(&candidate.orders[index])
        if candidate.orders[index].status == .confirmed && !candidate.orders[index].questions.isEmpty {candidate.orders[index].status = .review}
        _=commit(candidate)
    }
    func confirm(_ id:UUID) {update(id){if $0.questions.isEmpty{$0.status = .confirmed}}}
    func disconnect() {
        runID=UUID();polling?.cancel();polling=nil;api=nil;connected=false;connecting=false;connection="Получение остановлено"
    }
    func reconnectSaved() {
        guard !storageBlocked else{return}
        do{if let token=try TokenVault.read(){connect(token)}}catch{errorText="Не удалось открыть собственную запись токена в Связке ключей."}
    }
    func removeToken() {
        disconnect()
        do{try TokenVault.remove();bot=nil;connection="Токен удалён из Связки ключей"}catch{errorText="Связка ключей не позволила удалить токен."}
    }
    func connect(_ entered:String) {
        let token=entered.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !storageBlocked else{return}
        guard Token.valid(token) else{errorText=BotError.invalidToken.text;return}
        disconnect();let id=UUID();runID=id;connecting=true;connection="Проверяю бота…";errorText=""
        let client=BotAPI(token:token)
        polling=Task {
            do {
                let identity=try await client.connect()
                guard self.runID==id && !Task.isCancelled else{return}
                do{try TokenVault.save(token)}catch{throw TokenVault.VaultError.unavailable}
                self.bot=identity;self.api=client;self.connected=true;self.connecting=false
                while !Task.isCancelled && self.runID==id {
                    self.connection="Получение: @"+(identity.username ?? "бот")
                    do {
                        let updates=try await client.updates(offset:self.snapshot.nextOffsets[String(identity.id)])
                        guard self.runID==id && !Task.isCancelled else{return}
                        if !updates.isEmpty {
                            let candidate=Importer.applying(updates,botID:identity.id,to:self.snapshot)
                            guard self.commit(candidate) else{return}
                        }
                        if updates.isEmpty{try await Task.sleep(nanoseconds:500_000_000)}
                    } catch let e as BotError {
                        guard self.runID==id else{return}
                        switch e {
                        case .rateLimited(let seconds):
                            self.connection=e.text;try await Task.sleep(nanoseconds:UInt64(min(max(seconds,1),86400))*1_000_000_000)
                        case .network:
                            self.connection="Нет связи. Повтор получения через 10 сек.";try await Task.sleep(nanoseconds:10_000_000_000)
                        default:throw e
                        }
                    }
                }
            } catch is CancellationError { }
            catch {
                guard self.runID==id else{return}
                self.errorText=(error as? BotError)?.text ?? "Не удалось сохранить токен в Связке ключей. Подключение остановлено."
                self.connection="Подключение остановлено";self.connected=false;self.connecting=false;self.api=nil
            }
            if self.runID==id {self.polling=nil}
        }
    }
    func sendQuestion(_ id:UUID,text:String) {
        guard let order=snapshot.orders.first(where:{$0.id==id}),let api,connected,bot?.id==order.botID,order.chatID>0,order.questionDelivery.isEmpty else{return}
        // Persist an unknown outcome before attempting the network write: never auto-retry.
        var candidate=snapshot
        let index=candidate.orders.firstIndex{$0.id==id}!
        candidate.orders[index].questionDelivery="Результат отправки неизвестен. Проверьте диалог в Telegram; автоматического повтора нет."
        guard commit(candidate) else{return}
        Task {
            do{
                let sent=try await api.sendQuestion(chatID:order.chatID,text:text)
                self.update(id){$0.questionDelivery="Уточнение отправлено, сообщение №\(sent.message_id)."}
            }catch{self.errorText="Не удалось подтвердить отправку уточнения. Проверьте диалог в Telegram; повтор автоматически не выполняется."}
        }
    }
    func addDemo() {
        let now=Date()
        var candidate=snapshot
        guard !candidate.orders.contains(where:{$0.sourceKey=="demo:1"}) else{selected=candidate.orders.first{$0.sourceKey=="demo:1"}?.id;return}
        var one=Parser.parse(text:"На завтра 3 пачки кофе Арабика 1 кг и две бутылки сиропа ванильного 1 л. Самовывоз",customer:"Демо · Кофейня Утро",at:now,botID:0,chatID:0,messageID:1)
        one.sourceKey="demo:1"
        var two=Parser.parse(text:"На завтра кофе Арабика 1 кг 2 пачки; 1 бутылка сиропа ванильного 1 л. Самовывоз",customer:"Демо · Кофейня Парк",at:now,botID:0,chatID:0,messageID:2)
        two.sourceKey="demo:2"
        candidate.orders += [one,two]
        if commit(candidate){selected=one.id;summaryDate=Calendar.current.date(byAdding:.day,value:1,to:now)!}
    }
    func exportCSV() {
        let panel=NSSavePanel();panel.nameFieldStringValue="orders-\(Day.string(summaryDate)).csv";panel.allowedContentTypes=[.commaSeparatedText]
        let data=CSV.export(snapshot.orders,day:Day.string(summaryDate))
        panel.begin { response in
            guard response == .OK,let url=panel.url else{return}
            do{try data.write(to:url,options:.atomic)}catch{self.errorText="Не удалось записать CSV. Выберите доступную папку."}
        }
    }
}
