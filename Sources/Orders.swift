import Foundation

struct OrderItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var amount: String
    var unit: String
}
enum OrderStatus: String, Codable, CaseIterable {
    case review = "Проверить", confirmed = "Подтверждён", cancelled = "Отменён"
}
struct Order: Codable, Identifiable, Equatable {
    var id = UUID()
    var sourceKey: String
    var botID: Int64
    var chatID: Int64
    var messageID: Int64
    var updateID: Int64? = nil
    var customer: String
    var receivedAt: Date
    var rawText: String
    var day: String
    var address: String
    var pickup: Bool
    var items: [OrderItem]
    var status: OrderStatus = .review
    var note: String = ""
    var questionDelivery: String = ""

    var questions: [String] {
        var q: [String] = []
        if items.isEmpty { q.append("Уточните товары и количество для заказа.") }
        if !Day.valid(day) { q.append("На какую дату нужен заказ?") }
        if !pickup && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { q.append("Доставка по какому адресу или самовывоз?") }
        for (index,item) in items.enumerated() {
            let label = item.name.isEmpty ? "Позиция \(index+1)" : item.name
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { q.append("Какой товар в позиции \(index+1)?") }
            if Quantity.parse(item.amount) == nil { q.append("Сколько нужно: \(label)?") }
            if item.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { q.append("В каких единицах: \(label)?") }
            if ["пач.","уп.","бут.","кор."].contains(item.unit) && !Parser.matches(item.name, "[0-9]+(?:[.,][0-9]+)?\\s*(?:кг|гр?|мл|л)\\b") {
                q.append("Уточните размер упаковки или объём: \(label).")
            }
        }
        if !note.isEmpty { q.append(note) }
        return q
    }
    var questionText: String { "Здравствуйте! Уточните, пожалуйста:\n" + questions.map { "• " + $0 }.joined(separator:"\n") }
}

enum Quantity {
    static func parse(_ text: String) -> Decimal? {
        let s = text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:".")
        guard s.range(of:"^[0-9]+(?:\\.[0-9]{1,3})?$",options:.regularExpression) != nil,
              let d=Decimal(string:s,locale:Locale(identifier:"en_US_POSIX")),d>0,d<=1_000_000 else { return nil }
        return d
    }
    static func show(_ value: Decimal) -> String { NSDecimalNumber(decimal:value).stringValue.replacingOccurrences(of:".",with:",") }
}
enum Day {
    static func formatter() -> DateFormatter {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.calendar=Calendar(identifier:.gregorian)
        f.timeZone = .current;f.dateFormat="yyyy-MM-dd";f.isLenient=false;return f
    }
    static func string(_ date: Date)->String { formatter().string(from:date) }
    static func valid(_ day: String)->Bool {
        guard let d=formatter().date(from:day) else{return false};return string(d)==day
    }
}

enum Parser {
    static let numberWords = ["один":"1","одна":"1","одну":"1","одно":"1","два":"2","две":"2","три":"3","четыре":"4","пять":"5","шесть":"6","семь":"7","восемь":"8","девять":"9","десять":"10"]
    static let units = "(?:шт(?:ук[аи]?)?\\.?|кг|килограмм(?:а|ов)?|г|гр\\.?|грамм(?:а|ов)?|л|литр(?:а|ов)?|мл|пачк[а-я]*|упаков[а-я]*|бутыл[а-я]*|короб[а-я]*)"
    static func matches(_ text:String,_ pattern:String)->Bool { text.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil }
    static func replace(_ text:String,_ pattern:String,_ template:String)->String {
        guard let re=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]) else{return text}
        return re.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:template)
    }
    static func captures(_ text:String,_ pattern:String)->[String]? {
        guard let re=try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]),let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
        return (1..<m.numberOfRanges).map{ i in Range(m.range(at:i),in:text).map{String(text[$0])} ?? "" }
    }
    static func unit(_ raw:String)->String {
        let s=raw.lowercased()
        if s.hasPrefix("шт"){return "шт."};if s=="кг" || s.hasPrefix("килограмм"){return "кг"}
        if s=="г" || s.hasPrefix("гр"){return "г"};if s=="мл"{return "мл"}
        if s=="л" || s.hasPrefix("литр"){return "л"};if s.hasPrefix("пач"){return "пач."}
        if s.hasPrefix("упак"){return "уп."};if s.hasPrefix("бут"){return "бут."};if s.hasPrefix("кор"){return "кор."};return ""
    }
    static func parse(text:String,customer:String,at date:Date,botID:Int64,chatID:Int64,messageID:Int64)->Order {
        var result=Order(sourceKey:"\(botID):\(chatID):\(messageID)",botID:botID,chatID:chatID,messageID:messageID,customer:customer,receivedAt:date,rawText:text,day:"",address:"",pickup:matches(text,"самовывоз"),items:[])
        if matches(text,"\\b(?:отмен[а-я]*|исправ[а-я]*|вместо|замен[а-я]*)\\b") {
            result.note="Клиент просит отмену или изменение. Сверьте с предыдущим заказом вручную.";return result
        }
        var cleaned=String(text.prefix(8000))
        if let parts=captures(cleaned,"(?:^|\\n)\\s*адрес\\s*:\\s*([^\\n]+)") { result.address=parts[0].trimmingCharacters(in:.whitespaces) }
        cleaned=replace(cleaned,"(?:^|\\n)\\s*адрес\\s*:[^\\n]*", "\n")
        if let p=captures(text,"\\b(\\d{2})\\.(\\d{2})\\.(\\d{4})\\b") {
            let value="\(p[2])-\(p[1])-\(p[0])";if Day.valid(value){result.day=value}
            cleaned=replace(cleaned,"\\b(?:на\\s+)?\\d{2}\\.\\d{2}\\.\\d{4}\\b","")
        } else if matches(text,"\\bзавтра\\b") {
            result.day=Day.string(Calendar.current.date(byAdding:.day,value:1,to:date)!)
        } else if matches(text,"\\bсегодня\\b") { result.day=Day.string(date) }
        cleaned=replace(cleaned,"\\b(?:на\\s+)?(?:сегодня|завтра)\\b|\\bсамовывоз\\b","")
        for (word,digit) in numberWords { cleaned=replace(cleaned,"\\b"+word+"\\b",digit) }
        cleaned=replace(cleaned,"\\s+и\\s+(?=[0-9])",";")
        cleaned=replace(cleaned,",(?![0-9])|(?<![0-9]),",";")
        for raw in cleaned.components(separatedBy:CharacterSet(charactersIn:";\n")) {
            var clause=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            clause=replace(clause,"^(?:здравствуйте|привет|добрый день|пожалуйста|нужно|нужны|заказ|привезите|доставьте)\\s*[:,!]?\\s*","")
            clause=clause.trimmingCharacters(in:CharacterSet(charactersIn:" .,!:"))
            if clause.isEmpty || clause.hasPrefix("/"){continue}
            let number="([0-9]+(?:[.,][0-9]{1,3})?)"
            if let p=captures(clause,"^"+number+"\\s*("+units+")\\s+(.+)$") {
                result.items.append(OrderItem(name:p[2],amount:p[0],unit:unit(p[1])))
            } else if let p=captures(clause,"^(.+?)\\s+"+number+"\\s*("+units+")$") {
                result.items.append(OrderItem(name:p[0],amount:p[1],unit:unit(p[2])))
            } else if let p=captures(clause,"^"+number+"\\s+(.+)$") {
                result.items.append(OrderItem(name:p[1],amount:p[0],unit:""))
            } else if matches(clause,"[0-9]|кофе|сироп|молоко|хлеб|сахар") {
                result.items.append(OrderItem(name:clause,amount:"",unit:""))
            }
        }
        return result
    }
}

struct SummaryLine: Identifiable {
    let id:String;let name:String;let unit:String;var amount:Decimal
}
enum Summary {
    static func lines(_ orders:[Order],day:String)->[SummaryLine] {
        var result:[String:SummaryLine]=[:]
        for order in orders where order.status == .confirmed && order.day==day && order.questions.isEmpty {
            for item in order.items {
                guard let amount=Quantity.parse(item.amount) else{continue}
                let name=item.name.trimmingCharacters(in:.whitespacesAndNewlines)
                let u=item.unit.trimmingCharacters(in:.whitespacesAndNewlines)
                let key=name.lowercased()+"\u{001f}"+u.lowercased()
                if var old=result[key]{old.amount+=amount;result[key]=old}
                else{result[key]=SummaryLine(id:key,name:name,unit:u,amount:amount)}
            }
        }
        return result.values.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
}
enum CSV {
    static func cell(_ value:String)->String {
        var s=value
        if let first=s.trimmingCharacters(in:.whitespacesAndNewlines).first,"=+-@".contains(first){s="'"+s}
        return "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\""
    }
    static func export(_ orders:[Order],day:String)->Data {
        var rows=[["Дата","Клиент","Товар","Количество","Единица","Адрес","Источник"]]
        for o in orders where o.status == .confirmed && o.day==day && o.questions.isEmpty {
            for item in o.items { rows.append([o.day,o.customer,item.name,item.amount,item.unit,o.pickup ? "Самовывоз" : o.address,o.sourceKey]) }
        }
        return Data(("\u{feff}"+rows.map{$0.map(cell).joined(separator:";")}.joined(separator:"\r\n")+"\r\n").utf8)
    }
}

struct DeskSnapshot: Codable {
    var schemaVersion=1
    var orders:[Order]=[]
    var nextOffsets:[String:Int64]=[:]
}
struct DiskStore {
    let url:URL
    func load() throws->DeskSnapshot {
        if !FileManager.default.fileExists(atPath:url.path){return DeskSnapshot()}
        let saved=try JSONDecoder().decode(DeskSnapshot.self,from:Data(contentsOf:url))
        guard saved.schemaVersion==1 else{throw CocoaError(.fileReadCorruptFile)}
        return saved
    }
    func save(_ snapshot:DeskSnapshot)throws {
        let folder=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try JSONEncoder().encode(snapshot)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
enum Importer {
    static func applying(_ updates:[TGUpdate],botID:Int64,to state:DeskSnapshot)->DeskSnapshot {
        var next=state
        var keys=Set(state.orders.map(\.sourceKey))
        let previous=state.nextOffsets[String(botID)] ?? 0
        for update in updates.sorted(by:{$0.update_id<$1.update_id}) {
            guard update.update_id>=previous else{continue}
            if let msg=update.message,msg.chat.type=="private", !(msg.text ?? "").hasPrefix("/") {
                let key="\(botID):\(msg.chat.id):\(msg.message_id)"
                if !keys.contains(key) {
                    let text=msg.text ?? msg.caption ?? ""
                    var order=Parser.parse(text:text,customer:msg.from?.displayName ?? "Клиент \(msg.chat.id)",at:Date(timeIntervalSince1970:msg.date),botID:botID,chatID:msg.chat.id,messageID:msg.message_id)
                    order.updateID=update.update_id
                    if text.isEmpty {order.note="Сообщение без текста. Уточните заказ вручную."}
                    next.orders.append(order);keys.insert(key)
                }
            }
            if update.update_id<Int64.max {next.nextOffsets[String(botID)]=max(next.nextOffsets[String(botID)] ?? 0,update.update_id+1)}
        }
        return next
    }
}
