import Testing
@testable import VoxPalmEngine

@Test func 重画手柄仍保留所有已知按键且点选区不互相重叠() {
    let common = ["l2", "r2", "l1", "r1", "up", "left", "right", "down", "triangle", "square", "circle", "cross", "touchpad", "create", "options", "l3", "r3", "ps", "mute"]
    for (diagram, ids) in [(DeviceDiagram.dualSense, common), (.dualSenseEdge, common + ["fnLeft", "fnRight", "backLeft", "backRight"])] {
        #expect(Set(diagram.spots.map(\.id)) == Set(ids))
        for (index, spot) in diagram.spots.enumerated() {
            #expect(spot.button == DualSenseInput.button(spot.id))
            let a = spot.box
            #expect(a.x >= 0 && a.y >= 0 && a.x + a.w <= diagram.width && a.y + a.h <= diagram.height)
            for other in diagram.spots.dropFirst(index + 1) {
                let b = other.box
                #expect(a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y)
            }
        }
    }
}

@Test func 背面视角不会把左右背键映射对调() throws {
    let back = DeviceDiagram.dualSenseEdge.spots
    let left = try #require(back.first { $0.id == "backLeft" })
    let right = try #require(back.first { $0.id == "backRight" })
    #expect(left.box.midX > right.box.midX)
    #expect(left.button == DualSenseInput.button("backLeft"))
    #expect(right.button == DualSenseInput.button("backRight"))
}

@Test func 手柄缩略图只留正面且不改变完整映射() {
    for (diagram, count) in [(DeviceDiagram.dualSense, 19), (.dualSenseEdge, 23)] {
        let thumbnail = diagram.thumbnail
        #expect(thumbnail.width > thumbnail.height)
        #expect(thumbnail.parts.filter { $0.shape == .gamepad }.count == 1)
        #expect(!thumbnail.parts.contains { $0.style == .caption })
        #expect(!thumbnail.spots.contains { ["l1", "r1", "l2", "r2", "backLeft", "backRight"].contains($0.id) })
        for box in thumbnail.parts.map(\.box) + thumbnail.spots.map(\.box) {
            #expect(box.x >= 0 && box.y >= 0 && box.x + box.w <= thumbnail.width && box.y + box.h <= thumbnail.height)
        }
        #expect(diagram.spots.count == count)
    }
    #expect(DeviceDiagram.siriRemote.thumbnail == .siriRemote)
    #expect(DeviceDiagram.dualSenseEdge.thumbnail.spots.contains { $0.id == "fnLeft" })
}
