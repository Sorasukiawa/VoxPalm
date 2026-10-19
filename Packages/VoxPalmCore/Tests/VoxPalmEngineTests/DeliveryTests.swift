import Testing
@testable import VoxPalmEngine

// 出字、按回车前的目标检查（DeliveryRule）。

private let textArea = FieldFacts(role: "AXTextArea", valueSettable: true, text: "你好")
private let password = FieldFacts(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true)

@Test func 密码框绝不贴也不按回车() {
    #expect(DeliveryRule.kind(password) == .secure)
    #expect(DeliveryRule.paste(trusted: true, field: password, changed: false) == .secureField)
    #expect(DeliveryRule.sendReturn(trusted: true, field: password, changed: false) == .secureField)
    // 标了受保护内容的输入框也算密码框
    let protected = FieldFacts(role: "AXTextArea", valueSettable: true, protected: true)
    #expect(DeliveryRule.paste(trusted: true, field: protected, changed: false) == .secureField)
    // 角色直接写成密码框的也算
    #expect(DeliveryRule.kind(FieldFacts(role: "AXSecureTextField", valueSettable: true)) == .secure)
    // 目标变了也照样报密码框
    #expect(DeliveryRule.paste(trusted: true, field: password, changed: true) == .secureField)
}

@Test func 只往能打字的输入框贴() {
    #expect(DeliveryRule.paste(trusted: true, field: textArea, changed: false) == nil)
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: "AXTextField", valueSettable: true), changed: false) == nil)
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: "AXComboBox", valueSettable: true), changed: false) == nil)
    // 系统「终端」的输入区：文字区域，但值不可写
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: "AXTextArea", valueSettable: false), changed: false) == nil)
    // 只读的单行框、按钮、读不到焦点
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: "AXTextField", valueSettable: false), changed: false) == .notEditable)
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: "AXButton", valueSettable: true), changed: false) == .notEditable)
    #expect(DeliveryRule.paste(trusted: true, field: FieldFacts(role: nil, valueSettable: false), changed: false) == .notEditable)
    #expect(DeliveryRule.paste(trusted: true, field: nil, changed: false) == .notEditable)
}

@Test func 目标变了就不贴不按回车() {
    // 换了 App
    #expect(DeliveryRule.targetChanged(capturedPID: 10, currentPID: 11, sameElement: true))
    #expect(DeliveryRule.targetChanged(capturedPID: 10, currentPID: nil, sameElement: nil))
    // 同一个 App 换了输入框
    #expect(DeliveryRule.targetChanged(capturedPID: 10, currentPID: 10, sameElement: false))
    #expect(!DeliveryRule.targetChanged(capturedPID: 10, currentPID: 10, sameElement: true))
    // 按键那一刻没读到输入框：只比 App
    #expect(!DeliveryRule.targetChanged(capturedPID: 10, currentPID: 10, sameElement: nil))
    // 没记下目标（直接按「发送」键）：只看现在
    #expect(!DeliveryRule.targetChanged(capturedPID: nil, currentPID: 11, sameElement: nil))

    #expect(DeliveryRule.paste(trusted: true, field: textArea, changed: true) == .targetChanged)
    #expect(DeliveryRule.sendReturn(trusted: true, field: textArea, changed: true) == .targetChanged)
}

@Test func 缺辅助功能权限就只放剪贴板() {
    #expect(DeliveryRule.paste(trusted: false, field: textArea, changed: false) == .noPermission)
    #expect(DeliveryRule.paste(trusted: false, field: nil, changed: true) == .noPermission)
    #expect(DeliveryRule.sendReturn(trusted: false, field: textArea, changed: false) == .noPermission)
}

@Test func 回车只在有字的输入框里按() {
    #expect(DeliveryRule.sendReturn(trusted: true, field: textArea, changed: false) == nil)
    #expect(DeliveryRule.sendReturn(trusted: true, field: FieldFacts(role: "AXTextArea", valueSettable: true, text: ""), changed: false) == .emptyField)
    #expect(DeliveryRule.sendReturn(trusted: true, field: FieldFacts(role: "AXTextArea", valueSettable: true, text: " \n"), changed: false) == .emptyField)
    // 读不到字的不拦
    #expect(DeliveryRule.sendReturn(trusted: true, field: FieldFacts(role: "AXTextArea", valueSettable: true, text: nil), changed: false) == nil)
    #expect(DeliveryRule.sendReturn(trusted: true, field: FieldFacts(role: "AXButton", valueSettable: false, text: "确定"), changed: false) == .notEditable)
}
