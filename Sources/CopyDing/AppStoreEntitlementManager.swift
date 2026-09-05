import Foundation
import StoreKit

#if APP_STORE
@MainActor
final class AppStoreEntitlementManager: ObservableObject {
    static let shared = AppStoreEntitlementManager()

    static let trialProductID = "copyding.trial.14day"
    static let proProductID = "copyding.pro.lifetime"
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

    @Published private(set) var accessState: AccessState = .loading
    @Published private(set) var trialProduct: Product?
    @Published private(set) var proProduct: Product?
    @Published private(set) var lastErrorMessage: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = observeTransactions()
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        await loadProducts()
        await refreshEntitlements()
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [
                Self.trialProductID,
                Self.proProductID
            ])
            trialProduct = products.first(where: { $0.id == Self.trialProductID })
            proProduct = products.first(where: { $0.id == Self.proProductID })
        } catch {
            lastErrorMessage = "Could not load App Store purchases. Please try again."
        }
    }

    func startTrial() async -> Bool {
        guard let trialProduct else {
            lastErrorMessage = "The 14 day trial is temporarily unavailable."
            return false
        }
        return await purchase(trialProduct)
    }

    func buyPro() async -> Bool {
        guard let proProduct else {
            lastErrorMessage = "CopyDing Pro is temporarily unavailable."
            return false
        }
        return await purchase(proProduct)
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastErrorMessage = "Could not restore purchases. Please try again."
        }
    }

    func refreshEntitlements(now: Date = Date()) async {
        var trialPurchaseDate: Date?
        var hasPro = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.revocationDate == nil else { continue }

            switch transaction.productID {
            case Self.proProductID:
                hasPro = true
            case Self.trialProductID:
                trialPurchaseDate = transaction.purchaseDate
            default:
                break
            }
        }

        if hasPro {
            accessState = .pro
            return
        }

        guard let trialPurchaseDate else {
            accessState = .trialNotStarted
            return
        }

        let expiry = trialPurchaseDate.addingTimeInterval(Self.trialDuration)
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else {
            accessState = .trialExpired
            return
        }

        let days = max(1, Int(ceil(remaining / (24 * 60 * 60))))
        accessState = .trialActive(daysRemaining: days)
    }

    private func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastErrorMessage = "The App Store could not verify this purchase."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return true
            case .pending:
                lastErrorMessage = "The purchase is pending approval."
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastErrorMessage = "The purchase could not be completed. Please try again."
            return false
        }
    }

    private func observeTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { break }
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}
#else
@MainActor
final class AppStoreEntitlementManager {
    static let shared = AppStoreEntitlementManager()
    private init() {}
}
#endif
