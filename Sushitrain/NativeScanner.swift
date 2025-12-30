// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@preconcurrency import SushitrainCore

// MARK: - Scan State Persistence

/// Persistent state for tracking file modification times and scan progress
struct FolderScanState: Codable {
    var fileStates: [String: Date]  // [relative path: mtime]
    var lastScanCursor: String?     // Resume position (sorted path for resumable walk)
    var lastScanCompleted: Date?
    
    static func empty() -> FolderScanState {
        return FolderScanState(fileStates: [:], lastScanCursor: nil, lastScanCompleted: nil)
    }
}

// MARK: - Scan Result

/// Result of a folder scan operation
enum FolderScanResult {
    /// Scan completed successfully with list of changed paths
    case completed(changes: [String], deleted: [String])
    /// Scan was interrupted (timeout), will resume from cursor on next wake
    case interrupted(changes: [String], resumeFrom: String)
}

// MARK: - Folder Change Detector

/// Native Swift scanner for detecting file changes using APFS-optimized FileManager enumeration.
/// Designed to be resumable across app suspensions for iOS background sync.
class FolderChangeDetector {
    private let folderID: String
    private let folderURL: URL
    private let stateFileURL: URL
    private let folder: SushitrainFolder?
    
    /// Syncthing internal path prefixes (matches fs.IsInternal)
    private static let internalPrefixes = [".stfolder", ".stignore", ".stversions"]
    
    /// Syncthing temporary file prefixes (matches fs.IsTemporary)
    private static let tempPrefixes = [".syncthing.", "~syncthing~"]
    
    init(folderID: String, folderURL: URL, folder: SushitrainFolder? = nil) {
        self.folderID = folderID
        self.folderURL = folderURL
        self.folder = folder
        
        // Store state in Library/Application Support/FolderStates/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let statesDir = appSupport.appendingPathComponent("FolderStates", isDirectory: true)
        try? FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)
        self.stateFileURL = statesDir.appendingPathComponent("\(folderID).json")
    }
    
    // MARK: - State Persistence
    
    private func loadState() -> FolderScanState {
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(FolderScanState.self, from: data) else {
            return .empty()
        }
        return state
    }
    
    private func saveState(_ state: FolderScanState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }
    
    /// Clear cached state (e.g., when folder config changes)
    func invalidateCache() {
        try? FileManager.default.removeItem(at: stateFileURL)
    }
    
    // MARK: - Skip Logic (matching syncthing exactly)
    
    /// Check if path should be skipped (matches syncthing's IsTemporary + IsInternal)
    private func shouldSkip(_ relativePath: String) -> Bool {
        let filename = (relativePath as NSString).lastPathComponent
        
        // IsTemporary: .syncthing. or ~syncthing~ prefix
        for prefix in Self.tempPrefixes {
            if filename.hasPrefix(prefix) {
                return true
            }
        }
        
        // IsInternal: .stfolder, .stignore, .stversions (and their children)
        for internalPath in Self.internalPrefixes {
            if relativePath == internalPath || relativePath.hasPrefix(internalPath + "/") {
                return true
            }
        }
        
        return false
    }
    
    /// Check if file is ignored via .stignore (uses existing bridge)
    private func isIgnored(_ relativePath: String) -> Bool {
        guard let folder = folder else { return false }
        var isIgnored: ObjCBool = false
        folder.isPathIgnored(relativePath, isIgnored: &isIgnored)
        return isIgnored.boolValue
    }
    
    // MARK: - UTF-8 Normalization
    
    /// Normalize path to NFD (macOS/iOS native form) matching syncthing's normalizePath
    private func normalizePath(_ path: String) -> String {
        // iOS/macOS use NFD normalization
        return path.decomposedStringWithCanonicalMapping
    }
    
    // MARK: - Scanning
    
    /// Scan folder for changes with optional timeout for background execution
    /// - Parameters:
    ///   - timeout: Maximum time to spend scanning (default: no limit)
    /// - Returns: Scan result with changed paths or interruption point
    func scan(timeout: TimeInterval = .infinity) -> FolderScanResult {
        let startTime = Date()
        var state = loadState()
        var changes: [String] = []
        var walkedPaths = Set<String>()
        var currentCursor: String? = nil
        let resumeFrom = state.lastScanCursor
        var hasResumed = resumeFrom == nil  // If no cursor, we start from beginning
        
        Log.info("[NativeScanner] Scanning folder: \(folderID), resuming from: \(resumeFrom ?? "start")")
        
        // Create enumerator with mtime resource key for efficiency
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            Log.warn("[NativeScanner] Failed to create enumerator for \(folderURL)")
            return .completed(changes: [], deleted: [])
        }
        
        // Walk the filesystem
        for case let fileURL as URL in enumerator {
            // Calculate relative path
            let fullPath = fileURL.path
            guard fullPath.hasPrefix(folderURL.path) else { continue }
            var relativePath = String(fullPath.dropFirst(folderURL.path.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
            
            // Normalize path (NFD on Darwin)
            relativePath = normalizePath(relativePath)
            
            // Skip logic (before resumption check to maintain consistent ordering)
            if shouldSkip(relativePath) {
                if (relativePath as NSString).pathExtension.isEmpty {
                    // It's a directory, skip its contents too
                    enumerator.skipDescendants()
                }
                continue
            }
            
            // Resume logic: skip until we reach the cursor
            if !hasResumed {
                if relativePath == resumeFrom {
                    hasResumed = true
                }
                continue
            }
            
            // Check timeout
            if Date().timeIntervalSince(startTime) >= timeout {
                Log.info("[NativeScanner] Timeout reached, saving cursor at: \(relativePath)")
                state.lastScanCursor = currentCursor
                saveState(state)
                return .interrupted(changes: changes, resumeFrom: relativePath)
            }
            
            currentCursor = relativePath
            
            // Check if ignored via .stignore
            if isIgnored(relativePath) {
                continue
            }
            
            // Get file attributes
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  let isDirectory = resourceValues.isDirectory,
                  let isRegular = resourceValues.isRegularFile else {
                continue
            }
            
            // Only track files (directories are tracked implicitly)
            if isDirectory {
                continue
            }
            
            guard isRegular, let mtime = resourceValues.contentModificationDate else {
                continue
            }
            
            walkedPaths.insert(relativePath)
            
            // Compare against cached state
            if let cachedMtime = state.fileStates[relativePath] {
                // File exists in cache, check if modified
                if mtime != cachedMtime {
                    changes.append(relativePath)
                    state.fileStates[relativePath] = mtime
                }
            } else {
                // New file
                changes.append(relativePath)
                state.fileStates[relativePath] = mtime
            }
        }
        
        // Detect deleted files (only if we completed the full walk)
        var deleted: [String] = []
        if hasResumed && resumeFrom == nil {
            // Full walk completed, can detect deletions
            for cachedPath in state.fileStates.keys {
                if !walkedPaths.contains(cachedPath) {
                    deleted.append(cachedPath)
                }
            }
            // Remove deleted files from state
            for deletedPath in deleted {
                state.fileStates.removeValue(forKey: deletedPath)
            }
        }
        
        // Walk completed
        state.lastScanCursor = nil
        state.lastScanCompleted = Date()
        saveState(state)
        
        let elapsed = Date().timeIntervalSince(startTime)
        Log.info("[NativeScanner] Completed in \(Int(elapsed * 1000))ms: \(changes.count) changes, \(deleted.count) deleted")
        
        return .completed(changes: changes, deleted: deleted)
    }
}
