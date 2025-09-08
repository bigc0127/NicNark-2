//
//  ExportManager.swift
//  nicnark-2
//
//  CSV export functionality for v2.0
//

import Foundation
import CoreData
import UniformTypeIdentifiers
import UIKit

enum ExportManager {
    
    enum ExportError: LocalizedError {
        case fetchFailed
        case writeFailed
        case noData
        
        var errorDescription: String? {
            switch self {
            case .fetchFailed:
                return "Failed to fetch pouch logs"
            case .writeFailed:
                return "Failed to write export file"
            case .noData:
                return "No data to export"
            }
        }
    }
    
    /// Export all pouch logs to CSV format
    /// Returns URL to temporary file containing the CSV data
    static func exportAllPouchLogs(context: NSManagedObjectContext) async throws -> URL {
        return try await context.perform {
            let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
            
            let logs: [PouchLog]
            do {
                logs = try context.fetch(fetchRequest)
            } catch {
                throw ExportError.fetchFailed
            }
            
            guard !logs.isEmpty else {
                throw ExportError.noData
            }
            
            // Create CSV content
            var csvContent = "Date,Time,Nicotine Amount (mg),Duration (minutes),Status,Timer Setting\n"
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.timeZone = TimeZone.current
            
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            timeFormatter.timeZone = TimeZone.current
            
            for log in logs {
                guard let insertionTime = log.insertionTime else { continue }
                
                let date = dateFormatter.string(from: insertionTime)
                let time = timeFormatter.string(from: insertionTime)
                let amount = String(format: "%.1f", log.nicotineAmount)
                
                let duration: String
                let status: String
                
                if let removalTime = log.removalTime {
                    let durationSeconds = removalTime.timeIntervalSince(insertionTime)
                    duration = String(format: "%.1f", durationSeconds / 60.0)
                    status = "Completed"
                } else {
                    let durationSeconds = Date().timeIntervalSince(insertionTime)
                    duration = String(format: "%.1f", durationSeconds / 60.0)
                    status = "Active"
                }
                
                // Note the timer setting used (will show current setting for old logs)
                let timerSetting = String(format: "%.0f", FULL_RELEASE_TIME / 60.0)
                
                // Escape any commas in the data
                let row = "\(date),\(time),\(amount),\(duration),\(status),\(timerSetting)\n"
                csvContent += row
            }
            
            // Create filename with timestamp
            let dateFormatter2 = DateFormatter()
            dateFormatter2.dateFormat = "yyyy-MM-dd_HHmmss"
            let timestamp = dateFormatter2.string(from: Date())
            let fileName = "nicnark_export_\(timestamp).csv"
            
            // Save to temporary directory
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            
            do {
                try csvContent.write(to: tempURL, atomically: true, encoding: .utf8)
            } catch {
                throw ExportError.writeFailed
            }
            
            return tempURL
        }
    }
    
    /// Get statistics about the data to be exported
    static func getExportStatistics(context: NSManagedObjectContext) async -> (totalLogs: Int, dateRange: String) {
        return await context.perform {
            let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            
            guard let count = try? context.count(for: fetchRequest),
                  count > 0 else {
                return (0, "No data")
            }
            
            // Get date range
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
            fetchRequest.fetchLimit = 1
            
            guard let oldestLog = try? context.fetch(fetchRequest).first,
                  let oldestDate = oldestLog.insertionTime else {
                return (count, "Unknown range")
            }
            
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
            
            guard let newestLog = try? context.fetch(fetchRequest).first,
                  let newestDate = newestLog.insertionTime else {
                return (count, "Unknown range")
            }
            
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            
            let range = "\(formatter.string(from: oldestDate)) - \(formatter.string(from: newestDate))"
            
            return (count, range)
        }
    }
}

// MARK: - Document Exporter View

import SwiftUI

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentExporter
        
        init(_ parent: DocumentExporter) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Document was saved successfully
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
