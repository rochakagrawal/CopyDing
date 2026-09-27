import Foundation
import Combine
import StoreKit

#if APP_STORE
import AppKit
#endif

#if APP_STORE
@MainActor
final class AppStoreEntitlementManager: ObservableObject {
    static let shared = AppStoreEntitlementManager()

    static let trialProductID = "copyding.trial.14day"
    static let proProductID = "copyding.pro.lifetime.v2"
    static let trialDuration: TimeInterval = 14 * 24 * 60 * 60

    enum AccessState: Equatable {
        case loading
        case trialNotStarted
        case trialActive(daysRemaining: Int)
        case trialExpired
        case pro

        var canUseCopyDing: Bool {
            switch self {
            case .trialActive, .pro:
                return true
            case .loading, .trialNotStarted, .trialExpired:
                return false
            }
        }
    }

    static func accessState(
        hasPro: Bool,
        trialPurchaseDate: Date?,
        now: Date
    ) -> AccessState {
        if hasPro {
            return .pro
        }

        guard let trialPurchaseDate else {
            return .trialNotStarted
        }

        let expiry = trialPurchaseDate.addingTimeInterval(Self.trialDuration)
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else {
            return .trialExpired
        }

        let days = max(1, Int(ceil(remaining / (24 * 60 * 60))))
        return .trialActive(daysRemaining: days)
    }

    @Published private(set) var accessState: AccessState = .loading
    @Published private(set) var trialProduct: Product?
    @Published private(set) var proProduct: Product?
    @Published private(set) var lastErrorMessage: String?

    #if DEBUG
    @Published private(set) var debugAllFeaturesEnabled: Bool = {
        if let saved = UserDefaults.standard.object(forKey: "copyding.debugAllFeaturesEnabled") as? Bool {
            return saved
        }
        return true
    }()
    #endif

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = observeTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        print("[CopyDing StoreKit] Preparing products and entitlements")
        await loadProducts()
        await refreshEntitlements()
        print("[CopyDing StoreKit] Preparation finished. Access state: \(accessState)")
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [
                Self.trialProductID,
                Self.proProductID
            ])
            print("[CopyDing StoreKit] Loaded product IDs: \(products.map(\.id).joined(separator: ", "))")
            trialProduct = products.first(where: { $0.id == Self.trialProductID })
            proProduct = products.first(where: { $0.id == Self.proProductID })
            if trialProduct == nil || proProduct == nil {
                lastErrorMessage = "One or more CopyDing purchases are unavailable right now."
            } else {
                lastErrorMessage = nil
            }
        } catch {
            print("[CopyDing StoreKit] Product loading failed: \(error)")
            lastErrorMessage = "Could not load App Store purchases. Please try again."
        }
    }

    func startTrial(confirmingIn window: NSWindow? = nil) async -> Bool {
        print("[CopyDing StoreKit] Start trial tapped. Trial product loaded: \(trialProduct != nil)")
        guard let trialProduct else {
            lastErrorMessage = "The 14 day trial is temporarily unavailable."
            return false
        }
        return await purchase(trialProduct, confirmingIn: window)
    }

    func buyPro(confirmingIn window: NSWindow? = nil) async -> Bool {
        print("[CopyDing StoreKit] Upgrade tapped. Pro product loaded: \(proProduct != nil)")
        guard let proProduct else {
            lastErrorMessage = "CopyDing Pro is temporarily unavailable."
            return false
        }
        return await purchase(proProduct, confirmingIn: window)
    }

    func restorePurchases() async {
        print("[CopyDing StoreKit] Restore purchases tapped")
        do {
            try await AppStore.sync()
            lastErrorMessage = nil
            await refreshEntitlements()
        } catch {
            lastErrorMessage = "Could not restore purchases. Please try again."
        }
    }

    func refreshEntitlements(now: Date? = nil) async {
        var trialPurchaseDate: Date?
        var hasPro = false
        var entitlementCount = 0

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if apply(transaction, trialPurchaseDate: &trialPurchaseDate, hasPro: &hasPro) {
                    entitlementCount += 1
                }
            case .unverified(_, let error):
                print("[CopyDing StoreKit] Current entitlement was unverified: \(error)")
            }
        }

        // A local StoreKit transaction can be delivered through purchase()/updates
        // before currentEntitlements reflects it. Check the latest transaction for
        // each product so a successful purchase is not left looking like no access.
        if trialPurchaseDate == nil {
            if let result = await Transaction.latest(for: Self.trialProductID) {
                switch result {
                case .verified(let transaction):
                    if apply(transaction, trialPurchaseDate: &trialPurchaseDate, hasPro: &hasPro) {
                        entitlementCount += 1
                        print("[CopyDing StoreKit] Used latest trial transaction fallback")
                    }
                case .unverified(_, let error):
                    print("[CopyDing StoreKit] Latest trial transaction was unverified: \(error)")
                }
            }
        }

        if !hasPro {
            if let result = await Transaction.latest(for: Self.proProductID) {
                switch result {
                case .verified(let transaction):
                    if apply(transaction, trialPurchaseDate: &trialPurchaseDate, hasPro: &hasPro) {
                        entitlementCount += 1
                        print("[CopyDing StoreKit] Used latest Pro transaction fallback")
                    }
                case .unverified(_, let error):
                    print("[CopyDing StoreKit] Latest Pro transaction was unverified: \(error)")
                }
            }
        }

        let evaluationDate = now ?? debugEvaluationDate()
        accessState = Self.accessState(
            hasPro: hasPro,
            trialPurchaseDate: trialPurchaseDate,
            now: evaluationDate
        )
        print("[CopyDing StoreKit] Refreshed entitlements. Verified count: \(entitlementCount), access state: \(accessState)")
    }

    #if DEBUG
    func setDebugAllFeaturesEnabled(_ enabled: Bool) {
        debugAllFeaturesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "copyding.debugAllFeaturesEnabled")
        print("[CopyDing Debug] All-features override: \(enabled ? "enabled" : "disabled")")
    }

    func setDebugTrialExpired(_ expired: Bool) {
        UserDefaults.standard.set(
            expired ? Self.trialDuration + 60 : 0,
            forKey: "copyding.debugTrialTimeOffset"
        )
        print("[CopyDing Debug] Trial expiry simulation: \(expired ? "enabled" : "disabled")")
    }

    var debugTrialExpiryEnabled: Bool {
        UserDefaults.standard.double(forKey: "copyding.debugTrialTimeOffset") > 0
    }
    #endif

    private func purchase(_ product: Product, confirmingIn window: NSWindow?) async -> Bool {
        do {
            let result: Product.PurchaseResult
            if #available(macOS 15.2, *), let window {
                print("[CopyDing StoreKit] Starting AppKit purchase confirmation for product ID: \(product.id)")
                result = try await product.purchase(confirmIn: window)
            } else {
                print("[CopyDing StoreKit] Starting legacy purchase flow for product ID: \(product.id)")
                result = try await product.purchase()
            }
            switch result {
            case .success(let verification):
                print("[CopyDing StoreKit] Purchase returned success for product ID: \(product.id)")
                guard case .verified(let transaction) = verification else {
                    lastErrorMessage = "The App Store could not verify this purchase."
                    return false
                }
                applyVerifiedPurchase(transaction)
                await transaction.finish()
                lastErrorMessage = nil
                await refreshEntitlements()
                return true
            case .pending:
                lastErrorMessage = "The purchase is pending approval."
                return false
            case .userCancelled:
                print("[CopyDing StoreKit] Purchase was cancelled for product ID: \(product.id)")
                return false
            @unknown default:
                return false
            }
        } catch {
            print("[CopyDing StoreKit] Purchase failed for product ID \(product.id): \(error)")
            lastErrorMessage = "The purchase could not be completed. Please try again."
            return false
        }
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                switch result {
                case .verified(let transaction):
                    print("[CopyDing StoreKit] Transaction update received for product ID: \(transaction.productID)")
                    self?.applyVerifiedPurchase(transaction)
                    await transaction.finish()
                    await self?.refreshEntitlements()
                case .unverified(_, let error):
                    print("[CopyDing StoreKit] Transaction update was unverified: \(error)")
                }
            }
        }
    }

    private func applyVerifiedPurchase(_ transaction: Transaction) {
        guard transaction.revocationDate == nil else {
            print("[CopyDing StoreKit] Ignoring revoked transaction for product ID: \(transaction.productID)")
            return
        }

        switch transaction.productID {
        case Self.proProductID:
            accessState = .pro
            print("[CopyDing StoreKit] Applied Pro entitlement from verified transaction")
        case Self.trialProductID:
            accessState = Self.accessState(
                hasPro: false,
                trialPurchaseDate: transaction.purchaseDate,
                now: debugEvaluationDate()
            )
            print("[CopyDing StoreKit] Applied trial entitlement from verified transaction. Access state: \(accessState)")
        default:
            break
        }
    }

    @discardableResult
    private func apply(
        _ transaction: Transaction,
        trialPurchaseDate: inout Date?,
        hasPro: inout Bool
    ) -> Bool {
        guard transaction.revocationDate == nil else { return false }

        switch transaction.productID {
        case Self.proProductID:
            hasPro = true
        case Self.trialProductID:
            if trialPurchaseDate == nil || transaction.purchaseDate > trialPurchaseDate! {
                trialPurchaseDate = transaction.purchaseDate
            }
        default:
            return false
        }

        return true
    }

    private func debugEvaluationDate() -> Date {
        #if DEBUG
        let offset = UserDefaults.standard.double(forKey: "copyding.debugTrialTimeOffset")
        return Date().addingTimeInterval(offset)
        #else
        return Date()
        #endif
    }
}
#else
@MainActor
final class AppStoreEntitlementManager {
    static let shared = AppStoreEntitlementManager()
    private init() {}
}
#endif
