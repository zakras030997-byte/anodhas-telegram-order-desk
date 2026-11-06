import Foundation

struct TGUser: Codable { let id:Int64;var first_name:String?;var last_name:String?;var username:String?
    var displayName:String { [first_name,last_name].compactMap{$0}.joined(separator:" ").trimmingCharacters(in:.whitespaces).isEmpty ? (username.map{"@"+$0} ?? "Клиент") : [first_name,last_name].compactMap{$0}.joined(separator:" ") }
}
struct TGChat: Codable {let id:Int64;let type:String}
struct TGMessage: Codable {let message_id:Int64;var from:TGUser?;let chat:TGChat;let date:Double;var text:String?;var caption:String?}
struct TGUpdate: Codable {let update_id:Int64;var message:TGMessage?}
struct TGBot: Codable {let id:Int64;let is_bot:Bool;var username:String?;var first_name:String?}
struct TGWebhook: Codable {let url:String}
struct TGParameters: Decodable {var retry_after:Int?}
struct TGEnvelope<T:Decodable>:Decodable {let ok:Bool;var result:T?;var error_code:Int?;var parameters:TGParameters?}
enum BotMethod:String,Sendable {case getMe,getWebhookInfo,getUpdates,sendMessage}
enum BotError:Error,Equatable {
    case invalidToken,unauthorized,conflict,webhook,rateLimited(Int),network,invalidResponse
    var text:String {
        switch self {
        case .invalidToken:return "Проверьте формат токена BotFather."
        case .unauthorized:return "Telegram не принял токен. Проверьте его в BotFather."
        case .conflict:return "Бот уже получает сообщения через другое приложение. Получение остановлено."
        case .webhook:return "У бота настроен webhook. Используйте отдельного бота: его настройки не изменены."
        case .rateLimited(let seconds):return "Лимит Telegram. Следующая попытка не раньше чем через \(seconds) сек."
        case .network:return "Не удалось связаться с Telegram. Проверьте интернет."
        case .invalidResponse:return "Telegram вернул неожиданный ответ. Получение остановлено."
        }
    }
}
protocol BotTransport:Sendable {func post(_ method:BotMethod,token:String,body:Data) async throws->Data}
private final class NoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}
struct HTTPBotTransport:BotTransport {
    func post(_ method:BotMethod,token:String,body:Data) async throws->Data {
        guard Token.valid(token),let url=URL(string:"https://api.telegram.org/bot\(token)/\(method.rawValue)"),url.host=="api.telegram.org",url.scheme=="https" else{throw BotError.invalidToken}
        let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.timeoutIntervalForRequest=35;config.timeoutIntervalForResource=40
        let session=URLSession(configuration:config,delegate:NoRedirect(),delegateQueue:nil);defer{session.finishTasksAndInvalidate()}
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        do {
            let (data,_)=try await session.data(for:request)
            guard data.count<=8_000_000 else{throw BotError.invalidResponse}
            return data
        } catch is CancellationError {throw CancellationError()}
        catch let error as BotError {throw error}
        catch {if Task.isCancelled{throw CancellationError()};throw BotError.network}
    }
}
enum Token {
    static func valid(_ token:String)->Bool {token.range(of:"^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$",options:.regularExpression) != nil && token.count<200}
}
actor BotAPI {
    private let token:String
    private let transport:any BotTransport
    init(token:String,transport:any BotTransport=HTTPBotTransport()){self.token=token;self.transport=transport}
    private func request<T:Decodable>(_ method:BotMethod,_ body:[String:Any],as type:T.Type)async throws->T {
        guard Token.valid(token) else{throw BotError.invalidToken}
        let payload=try JSONSerialization.data(withJSONObject:body)
        let raw:Data
        do{raw=try await transport.post(method,token:token,body:payload)}
        catch is CancellationError{throw CancellationError()}
        catch let error as BotError{throw error}
        catch{throw BotError.network}
        guard let envelope=try? JSONDecoder().decode(TGEnvelope<T>.self,from:raw) else{throw BotError.invalidResponse}
        guard envelope.ok,let result=envelope.result else {
            switch envelope.error_code {case 401:throw BotError.unauthorized;case 409:throw BotError.conflict;case 429:throw BotError.rateLimited(max(1,envelope.parameters?.retry_after ?? 30));default:throw BotError.invalidResponse}
        }
        return result
    }
    func connect()async throws->TGBot {
        let bot=try await request(.getMe,[:],as:TGBot.self)
        guard bot.is_bot else{throw BotError.invalidResponse}
        let webhook=try await request(.getWebhookInfo,[:],as:TGWebhook.self)
        guard webhook.url.isEmpty else{throw BotError.webhook}
        return bot
    }
    func updates(offset:Int64?)async throws->[TGUpdate] {
        var body:[String:Any]=["timeout":20,"limit":100,"allowed_updates":["message"]]
        if let offset{body["offset"]=offset}
        return try await request(.getUpdates,body,as:[TGUpdate].self)
    }
    func sendQuestion(chatID:Int64,text:String)async throws->TGMessage {
        guard !text.isEmpty && text.count<=4000 else{throw BotError.invalidResponse}
        return try await request(.sendMessage,["chat_id":chatID,"text":text],as:TGMessage.self)
    }
}
