//
// TipStore.swift
// nicnark-2
//
// Fixed StoreKit 2 implementation with proper error handling
//

import Foundation
import StoreKit
import os.log

@MainActor
class TipStore: ObservableObject {
    // MARK: - Published Properties
    @Published var tips: [Product] = []
    @Published var purchasedTips: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage = ""
    
    // MARK: - Private Properties
    private let tipIdentifiers: Set<String> = [
        "small_coffee",   // $2.99
        "medium_coffee",  // $4.99
        "large_coffee"    // $9.99
    ]
    
    private var transactionListener: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "TipStore")
    
    // MARK: - Initialization
    init() {
        transactionListener = listenForTransactions()
        Task {
            await loadProducts()
            await restorePurchases()
        }
    }
    
    deinit {
        transactionListener?.cancel()
    }
    
    // MARK: - Product Loading
    func loadProducts() async {
        guard !isLoading else { return }
        
        isLoading = true
        errorMessage = ""
        
        do {
            logger.info("Loading products for identifiers: \(self.tipIdentifiers)")
            
            // Small delay to ensure StoreKit is ready
            try await Task.sleep(nanoseconds: 500_000_000)
            
            let products = try await Product.products(for: tipIdentifiers)
            
            if products.isEmpty {
                errorMessage = "No products available. Check StoreKit configuration."
                logger.warning("No products returned from StoreKit")
            } else {
                tips = products.sorted { $0.price < $1.price }
                errorMessage = ""
                logger.info("Successfully loaded \(products.count) products")
            }
            
        } catch {
            errorMessage = "Failed to load products: \(error.localizedDescription)"
            logger.error("Product loading failed: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    // MARK: - Purchase Handling
    func purchaseTip(_ product: Product) async {
        isLoading = true
        errorMessage = ""
        
        logger.info("Attempting purchase: \(product.displayName)")
        
        do {
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                logger.info("Purchase successful, verifying transaction")
                let transaction = try checkVerified(verification)
                await handleSuccessfulPurchase(transaction)
                await transaction.finish()
                
            case .userCancelled:
                errorMessage = "Purchase cancelled"
                logger.info("Purchase cancelled by user")
                
            case .pending:
                errorMessage = "Purchase pending approval"
                logger.info("Purchase pending approval")
                
            @unknown default:
                errorMessage = "Unknown purchase result"
                logger.warning("Unknown purchase result received")
            }
            
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            logger.error("Purchase failed: \(error.localizedDescription)")
        }
        
        isLoading = false
    }
    
    // MARK: - Transaction Verification
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            logger.error("Transaction verification failed")
            throw StoreKitError.unknown
        case .verified(let safe):
            logger.info("Transaction verified successfully")
            return safe
        }
    }
    
    // MARK: - Purchase Success Handling
    private func handleSuccessfulPurchase(_ transaction: Transaction) async {
        purchasedTips.insert(transaction.productID)
        
        logger.info("Tip purchase successful: \(transaction.productID)")
        
        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
    }
    
    // MARK: - Transaction Listener
    private func listenForTransactions() -> Task<Void, Never> {
        return Task.detached { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                self.logger.info("Starting transaction listener")
            }
            
            for await result in Transaction.updates {
                do {
                    let transaction = try await MainActor.run {
                        try self.checkVerified(result)
                    }
                    await self.handleSuccessfulPurchase(transaction)
                    await transaction.finish()
                    await MainActor.run {
                        self.logger.info("Background transaction processed: \(transaction.productID)")
                    }
                } catch {
                    await MainActor.run {
                        self.logger.error("Transaction verification failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    // MARK: - Restore Purchases
    private func restorePurchases() async {
        logger.info("Restoring purchases")
        
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                purchasedTips.insert(transaction.productID)
            } catch {
                logger.error("Failed to restore purchase: \(error.localizedDescription)")
            }
        }
        
        logger.info("Purchase restoration complete")
    }
    
    // MARK: - Manual Refresh
    func refreshProducts() async {
        logger.info("Manual product refresh requested")
        await loadProducts()
    }
}
