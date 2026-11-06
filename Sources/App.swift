import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DeskView:View {
    @StateObject private var store=DeskStore()
    @State private var token=""
    @State private var question=""
    @State private var questionOrder:UUID?
    @State private var confirmQuestion=false

    var body:some View {
        VStack(spacing:0) {
            HStack {
                Image(systemName:"tray.and.arrow.down.fill").font(.system(size:27)).foregroundStyle(.orange)
                VStack(alignment:.leading){Text("Заказы из Telegram").font(.title2.bold());Text("Сообщение → проверка → заказ на день").foregroundStyle(.secondary)}
                Spacer();Button("Демо-пример"){store.addDemo()}.accessibilityIdentifier("load-demo")
            }.padding(20)
            HStack(spacing:10) {
                SecureField("Токен бота из BotFather",text:$token).textFieldStyle(.roundedBorder).accessibilityIdentifier("bot-token")
                Button(store.connecting ? "Проверка…" : "Подключить"){store.connect(token)}.disabled(store.connecting || token.isEmpty || store.storageBlocked)
                Button("Сохранённый бот"){store.reconnectSaved()}.disabled(store.connecting || store.storageBlocked)
                Button("Остановить"){store.disconnect()}.disabled(!store.connected && !store.connecting)
                Menu("Ещё") {Button("Удалить сохранённый токен"){store.removeToken()}}
            }.padding(.horizontal,20)
            HStack {
                Label(store.connection,systemImage:store.connected ? "circle.fill" : "circle").foregroundStyle(store.connected ? .green : .secondary)
                Spacer();Text("Токен — только в Связке ключей").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal,20).padding(.vertical,10)
            Divider()
            HSplitView {
                VStack(alignment:.leading,spacing:0) {
                    Text("Входящие · \(store.orders.count)").font(.headline).padding(12)
                    List(selection:$store.selected) {
                        ForEach(store.orders) { order in
                            VStack(alignment:.leading,spacing:5) {
                                Text(order.customer).font(.headline)
                                Text(order.items.map{($0.amount.isEmpty ? "?" : $0.amount)+" "+$0.unit+" "+$0.name}.joined(separator:"; "))
                                    .lineLimit(2).foregroundStyle(.secondary)
                                HStack {Text(order.status.rawValue);Spacer();Text(order.day.isEmpty ? "Без даты" : order.day)}.font(.caption)
                            }.padding(.vertical,5).tag(order.id)
                        }
                    }.accessibilityIdentifier("orders-list")
                }.frame(minWidth:260,idealWidth:300,maxWidth:370)
                ScrollView {
                    if let order=store.selectedOrder { editor(order).padding(20) }
                    else {
                        VStack(alignment:.leading,spacing:15) {
                            Text("Подключите своего бота").font(.title2.bold())
                            Text("Вставьте токен BotFather. Новые личные сообщения боту появятся слева. Для первого знакомства нажмите «Демо-пример».")
                            Text("Получение работает, пока приложение открыто и Mac в сети. Переписку вашего личного Telegram приложение не читает.").foregroundStyle(.secondary)
                        }.padding(30)
                    }
                }.frame(minWidth:430)
                VStack(alignment:.leading,spacing:12) {
                    Text("Сводка на день").font(.headline)
                    DatePicker("Дата",selection:$store.summaryDate,displayedComponents:.date).datePickerStyle(.field).accessibilityIdentifier("summary-date")
                    Text("Только подтверждённые заказы").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    if store.summary.isEmpty {Text("Пока нет подтверждённых позиций.").foregroundStyle(.secondary)}
                    ForEach(store.summary){line in
                        VStack(alignment:.leading,spacing:4){Text(line.name);Text(Quantity.show(line.amount)+" "+line.unit).font(.headline)}
                    }
                    Spacer()
                    Button("Экспорт CSV"){store.exportCSV()}.disabled(store.summary.isEmpty).accessibilityIdentifier("export-csv")
                    Text("ANODHAS AI · 1.0.0").font(.caption2).foregroundStyle(.secondary)
                }.padding(16).frame(minWidth:235,idealWidth:265,maxWidth:330)
            }
        }
        .frame(minWidth:1050,minHeight:700).tint(.orange)
        .alert("Не удалось выполнить действие",isPresented:Binding(get:{!store.errorText.isEmpty},set:{if !$0{store.errorText=""}})){Button("Понятно"){store.errorText=""}} message:{Text(store.errorText)}
        .alert("Отправить уточнение клиенту?",isPresented:$confirmQuestion) {
            Button("Отмена",role:.cancel){}
            Button("Отправить"){if let id=questionOrder{store.sendQuestion(id,text:question)}}
        } message:{Text((store.selectedOrder?.customer ?? "Клиент")+"\n\n"+question)}
        .onChange(of:store.connected){value in if value{token=""}}
        .task{store.reconnectSaved()}
    }

    private func binding(_ order:Order,_ key:WritableKeyPath<Order,String>)->Binding<String> {
        Binding(get:{store.snapshot.orders.first{$0.id==order.id}?[keyPath:key] ?? ""},set:{v in store.update(order.id){$0[keyPath:key]=v}})
    }
    private func itemBinding(_ order:Order,_ item:OrderItem,_ key:WritableKeyPath<OrderItem,String>)->Binding<String> {
        Binding(get:{store.snapshot.orders.first{$0.id==order.id}?.items.first{$0.id==item.id}?[keyPath:key] ?? ""},set:{v in store.update(order.id){o in if let i=o.items.firstIndex(where:{$0.id==item.id}){o.items[i][keyPath:key]=v}}})
    }
    private func editor(_ order:Order)->some View {
        VStack(alignment:.leading,spacing:15) {
            HStack {Text("Проверка заказа").font(.title2.bold());Spacer();Text(order.status.rawValue).foregroundStyle(.secondary)}
            if order.botID==0 {Label("Демонстрационные данные",systemImage:"testtube.2").foregroundStyle(.orange)}
            Text("Клиент").font(.caption).foregroundStyle(.secondary)
            TextField("Имя клиента",text:binding(order,\.customer)).textFieldStyle(.roundedBorder)
            Text("Дата исполнения · ГГГГ-ММ-ДД").font(.caption).foregroundStyle(.secondary)
            TextField("Например, 2026-11-07",text:binding(order,\.day)).textFieldStyle(.roundedBorder).accessibilityIdentifier("order-date")
            Toggle("Самовывоз",isOn:Binding(get:{store.selectedOrder?.pickup ?? false},set:{v in store.update(order.id){$0.pickup=v}}))
            if !order.pickup {TextField("Адрес доставки",text:binding(order,\.address)).textFieldStyle(.roundedBorder)}
            Divider();Text("Позиции").font(.headline)
            ForEach(order.items){item in
                VStack(alignment:.leading,spacing:7) {
                    TextField("Товар и размер упаковки",text:itemBinding(order,item,\.name)).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Количество",text:itemBinding(order,item,\.amount)).frame(width:100).accessibilityLabel("Количество")
                        TextField("Единица",text:itemBinding(order,item,\.unit)).frame(width:100).accessibilityLabel("Единица")
                        Spacer()
                        Button("Убрать"){store.update(order.id){$0.items.removeAll{$0.id==item.id}}}
                    }.textFieldStyle(.roundedBorder)
                }.padding(.vertical,5)
            }
            Button("Добавить позицию"){store.update(order.id){$0.items.append(OrderItem(name:"",amount:"",unit:""))}}
            if !order.questions.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    Text("Нужно уточнить").font(.headline)
                    ForEach(Array(order.questions.enumerated()),id:\.offset){_,q in Text("• "+q)}
                }.foregroundStyle(.orange)
                HStack {
                    Button("Скопировать вопросы") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(order.questionText,forType:.string)}
                    Button("Отправить через бота") {question=order.questionText;questionOrder=order.id;confirmQuestion=true}
                        .disabled(!store.connected || store.bot?.id != order.botID || order.botID==0 || !order.questionDelivery.isEmpty)
                }
                if !order.note.isEmpty {Button("Изменение проверено оператором"){store.update(order.id){$0.note=""}}}
            }
            if !order.questionDelivery.isEmpty {Text(order.questionDelivery).font(.caption).foregroundStyle(.secondary)}
            HStack {
                Button("Подтвердить заказ"){store.confirm(order.id)}.buttonStyle(.borderedProminent).disabled(!order.questions.isEmpty || order.status == .cancelled).accessibilityIdentifier("confirm-order")
                Button(order.status == .cancelled ? "Вернуть на проверку" : "Отменить заказ") {store.update(order.id){$0.status = $0.status == .cancelled ? .review : .cancelled}}
            }
            Divider();Text("Исходное сообщение").font(.headline)
            Text(order.rawText.isEmpty ? "Сообщение без текста" : order.rawText).textSelection(.enabled).foregroundStyle(.secondary)
            Text("\(order.receivedAt.formatted()) · источник \(order.sourceKey)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

final class DeskDelegate:NSObject,NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
@main
struct OrderDeskApp:App {
    @NSApplicationDelegateAdaptor(DeskDelegate.self) var delegate
    var body:some Scene {
        WindowGroup("Заказы из Telegram"){DeskView()}.defaultSize(width:1280,height:820).commands{CommandGroup(replacing:.newItem){}}
    }
}
