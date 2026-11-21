import Foundation
import CloudKit
import UIKit

/// 비전 앱 → 아이폰 앱 '바로' 알리기 (0.8.0).
/// 키-값 저장소(CloudPet)는 아이폰 앱이 켜져 있을 때만 읽혀서, 비전에서 밥을 준 뒤에도 아이폰은 예전 예약대로 '배고파해요'를 울렸음.
/// 비전 앱이 상태를 클라우드킷(개인 데이터베이스의 전용 구역)에 올리면, 아이폰 앱은 그 구역 구독으로 '조용한 푸시'를 받아
/// 백그라운드에서 깨어나 새 상태로 알림을 다시 맞춤. 서버 없음 (애플 아이클라우드만)
enum CloudSync {
    static let containerID = "iCloud.com.blankishworks.another-fam"
    static let zoneID = CKRecordZone.ID(zoneName: "Pet", ownerName: CKCurrentUserDefaultName)
    static let recordID = CKRecord.ID(recordName: "pet", zoneID: zoneID)
    static let subID = "pet-changes"

    private static var db: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }
    nonisolated(unsafe) private static var zoneReady = false
    nonisolated(unsafe) private static var lastPush: Double = 0
    nonisolated(unsafe) private static var lastSig = ""

    private static func ensureZone() async -> Bool {
        if zoneReady { return true }
        do {
            _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            zoneReady = true
        } catch { return false }
        return true
    }

    /// 비전 앱: 알림에 영향을 주는 값이 바뀌었거나(10초 간격) 5분이 지났거나 force(공간을 닫을 때)면 올림
    /// 0.10.15: 가족(여러 팸) 전체를 올림 — 어느 팸이든 알림에 영향을 주는 값이 바뀌면
    static func push(_ f: Family, data: Foundation.Data, force: Bool = false) {
        let r = { (x: Float) in Int((x * 10).rounded()) }
        let sig = f.pets.map { p in
            "\(p.id.prefix(4))\(r(p.food))\(r(p.water))\(r(p.fun))\(r(p.love))\(r(p.potty))\(p.poops)\(p.asleep)\(r(p.bottle))\(p.together)\(r(p.foodBowl))\(r(p.waterBowl))"
        }.joined(separator: "|")
        let now = Date().timeIntervalSince1970
        let changed = sig != lastSig
        guard force || (changed && now - lastPush > 10) || now - lastPush > 300 else { return }
        lastPush = now
        lastSig = sig
        Task.detached(priority: force ? .userInitiated : .utility) {
            // 공간을 닫거나 앱이 뒤로 갈 때(force)는 올리기가 끝날 때까지 앱이 멈추지 않게 시간을 빌림
            // (0.9: 닫는 순간 올리던 것이 끊겨, 아이폰은 계속 '지금 함께 있어요'로 보였음)
            let bg: UIBackgroundTaskIdentifier = force ? await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "af.push", expirationHandler: nil) } : .invalid
            if await ensureZone() {
                let rec = CKRecord(recordType: "Pet", recordID: recordID)
                rec["state"] = data as CKRecordValue
                rec["at"] = Date() as CKRecordValue
                // 덮어쓰기 (읽어 오지 않고 늘 새 값으로)
                _ = try? await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: false)
            }
            if bg != .invalid { await MainActor.run { UIApplication.shared.endBackgroundTask(bg) } }
        }
    }

    /// 아이폰 앱: 마지막으로 올라온 상태
    static func pull() async -> Foundation.Data? {
        guard let rec = try? await db.record(for: recordID) else { return nil }
        return rec["state"] as? Foundation.Data
    }

    /// 아이폰 앱: 구역이 바뀌면 조용한 푸시로 깨워 달라고 등록 (한 번 등록하면 남지만 켤 때마다 다시 해도 됨)
    static func subscribe() async {
        guard await ensureZone() else { return }
        let sub = CKDatabaseSubscription(subscriptionID: subID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        _ = try? await db.modifySubscriptions(saving: [sub], deleting: [])
    }
}
