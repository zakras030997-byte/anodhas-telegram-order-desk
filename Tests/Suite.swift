import Foundation

actor MockTransport:BotTransport {
    var replies:[BotMethod:[Data]]
    var calls:[(BotMethod,[String:Any])]=[]
    init(_ replies:[BotMethod:[String]]){self.replies=replies.mapValues{$0.map{Data($0.utf8)}}}
    func post(_ method:BotMethod,token:String,body:Data)async throws->Data {
        calls.append((method,(try? JSONSerialization.jsonObject(with:body) as? [String:Any]) ?? [:]))
        guard var values=replies[method],!values.isEmpty else{throw BotError.network}
        let next=values.removeFirst();replies[method]=values;return next
    }
    func count()->Int{calls.count}
    func lastBody()->[String:Any]{calls.last?.1 ?? [:]}
}

@main struct Suite {
    static func main()async throws {
        var checks:[String]=[]
        func test(_ name:String,_ condition:Bool) {if !condition{fatalError("FAILED: "+name)};checks.append(name)}
        let now=Day.formatter().date(from:"2026-11-06")!
        func parse(_ text:String)->Order{Parser.parse(text:text,customer:"Демо",at:now,botID:123,chatID:10,messageID:1)}
        let simple=parse("На завтра 3 пачки кофе Арабика 1 кг и две бутылки сиропа ванильного 1 л. Самовывоз")
        test("two ordered products",simple.items.count==2)
        test("digits quantity",simple.items[0].amount=="3")
        test("written Russian quantity",simple.items[1].amount=="2")
        test("pack normalized",simple.items[0].unit=="пач.")
        test("bottle normalized",simple.items[1].unit=="бут.")
        test("tomorrow relative to message",simple.day=="2026-11-07")
        test("pickup recognized",simple.pickup)
        test("complete draft needs operator but no missing data",simple.questions.isEmpty && simple.status == .review)
        let reverse=parse("На сегодня кофе Арабика 1 кг 2 пачки; 1 бутылка сиропа ванильного 1 л. Самовывоз")
        test("trailing quantity",reverse.items.first?.amount=="2")
        test("capacity stays in product name",reverse.items.first?.name=="кофе Арабика 1 кг")
        test("today date",reverse.day=="2026-11-06")
        let decimal=parse("На 12.11.2026 1,5 кг яблок; 0.5 л масла\nАдрес: улица Тестовая, 8")
        test("decimal comma preserved",decimal.items.first?.amount=="1,5")
        test("decimal dot preserved",decimal.items.last?.amount=="0.5")
        test("full date",decimal.day=="2026-11-12")
        test("address not parsed as quantity",decimal.items.count==2 && decimal.address=="улица Тестовая, 8")
        let vague=parse("3 пачки кофе и два ванильных сиропа")
        test("missing delivery day not guessed",vague.day.isEmpty)
        test("missing bottle size needs clarification",vague.questions.contains{$0.contains("размер упаковки")})
        test("missing unit not guessed",vague.items[1].unit.isEmpty)
        test("missing address needs clarification",vague.questions.contains{$0.contains("адрес")})
        test("invalid date rejected",!Day.valid("2026-02-30"))
        test("invalid input format rejected",!Day.valid("06.11.2026"))
        test("cancellation not silently applied",parse("Отмени прошлый заказ").items.isEmpty && !parse("Отмени прошлый заказ").note.isEmpty)
        test("replacement not silently applied",!parse("Вместо кофе нужно молоко").note.isEmpty)
        test("non-order text remains unresolved",parse("Привет!").items.isEmpty)
        test("zero rejected",Quantity.parse("0")==nil)
        test("negative rejected",Quantity.parse("-2")==nil)
        test("negative text not turned positive",parse("На завтра -2 кг яблок. Самовывоз").items.first?.amount.isEmpty == true)
        test("exponential not accepted",Quantity.parse("1e3")==nil)
        test("too much precision rejected",Quantity.parse("1.2345")==nil)
        test("decimal exact",Quantity.parse("0,1")!+Quantity.parse("0.2")! == Decimal(string:"0.3")!)
        var confirmed=simple;confirmed.status = .confirmed
        var second=reverse;second.status = .confirmed;second.day=simple.day;second.sourceKey="123:11:1"
        let lines=Summary.lines([confirmed,second],day:simple.day)
        test("same product sums",lines.first{$0.name=="кофе Арабика 1 кг"}?.amount==5)
        test("same bottle sums",lines.first{$0.unit=="бут."}?.amount==3)
        test("unconfirmed excluded",Summary.lines([simple],day:simple.day).isEmpty)
        test("other date excluded",Summary.lines([confirmed],day:"2026-11-08").isEmpty)
        var cancelled=confirmed;cancelled.status = .cancelled
        test("cancelled excluded",Summary.lines([cancelled],day:simple.day).isEmpty)
        var different=confirmed;different.items[0].unit="кг"
        test("different unit not merged",Summary.lines([confirmed,different],day:simple.day).filter{$0.name==confirmed.items[0].name}.count==2)
        var incomplete=confirmed;incomplete.items[0].amount=""
        test("invalid confirmed data never enters summary",Summary.lines([incomplete],day:simple.day).isEmpty)
        test("csv formula escaped",CSV.cell("=1+1")=="\"'=1+1\"")
        test("csv whitespace formula escaped",CSV.cell("  @SUM(A1)").hasPrefix("\"'"))
        test("csv quotes escaped",CSV.cell("a\"b")=="\"a\"\"b\"")
        test("csv UTF8 BOM",CSV.export([confirmed],day:simple.day).starts(with:[239,187,191]))
        test("csv excludes review",!String(data:CSV.export([simple],day:simple.day),encoding:.utf8)!.contains("Арабика"))
        let msg=TGMessage(message_id:1,from:TGUser(id:10,first_name:"Тест",last_name:nil,username:nil),chat:TGChat(id:10,type:"private"),date:now.timeIntervalSince1970,text:simple.rawText,caption:nil)
        let update=TGUpdate(update_id:100,message:msg)
        let imported=Importer.applying([update,update],botID:123,to:DeskSnapshot())
        test("same batch duplicate suppressed",imported.orders.count==1)
        test("offset advanced after accepted update",imported.nextOffsets["123"]==101)
        test("source event ID retained",imported.orders.first?.updateID==100)
        test("replayed batch suppressed",Importer.applying([update],botID:123,to:imported).orders.count==1)
        test("separate bot identity",Importer.applying([update],botID:124,to:imported).orders.count==2)
        let otherUser=TGMessage(message_id:1,from:TGUser(id:11,first_name:"Другой",last_name:nil,username:nil),chat:TGChat(id:11,type:"private"),date:msg.date,text:msg.text,caption:nil)
        let bothUsers=Importer.applying([TGUpdate(update_id:101,message:otherUser)],botID:123,to:imported)
        test("same message ID in different chats remains separate",bothUsers.orders.count==2 && Set(bothUsers.orders.map(\.chatID)).count==2)
        test("sender metadata preserved",bothUsers.orders.last?.customer=="Другой")
        var group=msg;group=TGMessage(message_id:1,from:msg.from,chat:TGChat(id:-10,type:"group"),date:msg.date,text:msg.text,caption:nil)
        test("groups excluded",Importer.applying([TGUpdate(update_id:101,message:group)],botID:123,to:imported).orders.count==1)
        let command=TGMessage(message_id:2,from:msg.from,chat:msg.chat,date:msg.date,text:"/start",caption:nil)
        test("start is not an order",Importer.applying([TGUpdate(update_id:101,message:command)],botID:123,to:imported).orders.count==1)
        let image=TGMessage(message_id:3,from:msg.from,chat:msg.chat,date:msg.date,text:nil,caption:nil)
        test("nontext retained for review",!Importer.applying([TGUpdate(update_id:102,message:image)],botID:123,to:imported).orders.last!.note.isEmpty)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("orderdesk-tests-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let disk=DiskStore(url:folder.appendingPathComponent("state.json"))
        try disk.save(imported)
        let restored=try disk.load()
        test("restart restores offset and order atomically",restored.nextOffsets["123"]==101 && restored.orders.count==1)
        test("restart dedup",Importer.applying([update],botID:123,to:restored).orders.count==1)
        let bad=DiskStore(url:folder)
        do{try bad.save(imported);test("disk failure",false)}catch{test("disk failure propagates",true)}
        try Data("corrupt".utf8).write(to:disk.url)
        do{_=try disk.load();test("corrupt data",false)}catch{test("corrupt data rejected",true)}
        test("corrupt file not overwritten",try String(contentsOf:disk.url,encoding:.utf8)=="corrupt")
        let fakeToken="123456:"+String(repeating:"x",count:32)
        test("token format",Token.valid(fakeToken))
        test("URL is not token",!Token.valid("https://example.com/"))
        let good="{\"ok\":true,\"result\":{\"id\":123,\"is_bot\":true,\"username\":\"test_demo_bot\"}}"
        let transport=MockTransport([.getMe:[good],.getWebhookInfo:["{\"ok\":true,\"result\":{\"url\":\"\"}}"],.getUpdates:["{\"ok\":true,\"result\":[]}"]])
        let api=BotAPI(token:fakeToken,transport:transport)
        let identity=try await api.connect();test("protocol connects bot",identity.id==123)
        let updates=try await api.updates(offset:101);test("protocol decodes empty updates",updates.isEmpty)
        let body=await transport.lastBody()
        test("protocol offset transmitted",body["offset"] as? Int==101)
        test("poll long timeout",body["timeout"] as? Int==20)
        test("only message updates requested",body["allowed_updates"] as? [String]==["message"])
        let wh=MockTransport([.getMe:[good],.getWebhookInfo:["{\"ok\":true,\"result\":{\"url\":\"https://example.com/webhook\"}}"]])
        do{_=try await BotAPI(token:fakeToken,transport:wh).connect();test("webhook block",false)}catch{test("existing webhook blocks without deletion",error as? BotError == .webhook)}
        test("webhook check does not poll",await wh.count()==2)
        for (code,expected) in [(401,BotError.unauthorized),(409,.conflict),(429,.rateLimited(7))] {
            let t=MockTransport([.getMe:["{\"ok\":false,\"error_code\":\(code),\"parameters\":{\"retry_after\":7}}"]])
            do{_=try await BotAPI(token:fakeToken,transport:t).connect();test("HTTP error",false)}catch{test("protocol handles \(code)",error as? BotError == expected)}
        }
        let broken=MockTransport([.getMe:["not json"]])
        do{_=try await BotAPI(token:fakeToken,transport:broken).connect();test("bad JSON",false)}catch{test("bad protocol response rejected",error as? BotError == .invalidResponse)}
        let missing=MockTransport([:])
        do{_=try await BotAPI(token:fakeToken,transport:missing).connect();test("network",false)}catch{test("network error sanitized",error as? BotError == .network)}
        let sending=MockTransport([.sendMessage:["{\"ok\":true,\"result\":{\"message_id\":9,\"chat\":{\"id\":10,\"type\":\"private\"},\"date\":0,\"text\":\"Уточните дату\"}}"]])
        let sent=try await BotAPI(token:fakeToken,transport:sending).sendQuestion(chatID:10,text:"Уточните дату")
        test("manual send acknowledgement",sent.message_id==9)
        test("no automatic send retry",await sending.count()==1)
        let failedSend=MockTransport([:])
        do{_=try await BotAPI(token:fakeToken,transport:failedSend).sendQuestion(chatID:10,text:"Уточните дату");test("failed send",false)}catch{test("uncertain send surfaces safe error",error as? BotError == .network)}
        test("uncertain send never retried",await failedSend.count()==1)
        let report:[String:Any]=["checksPassed":checks.count,"checks":checks,"mockBotAPI":true,"realTelegramE2E":false,"scope":"local model, parser, persistence, export, mocked Bot API; not live Telegram"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]));print("")
    }
}
