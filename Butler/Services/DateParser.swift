//
//  DateParser.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation

/// Utility to parse various date string formats into standard Date objects
struct DateParser {
    
    /// Try to parse a string into a Date
    static func parse(_ text: String) -> Date? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Define Regex Patterns to extract potential date substrings.
        // This solves the issue where OCR outputs are noisy (e.g. "EXP: 2026.06.19 12A").
        let patterns = [
            // Year-Month-Day structure: yyyy-MM-dd, yy.MM.dd, 2026 06 19, etc.
            "([0-9]{4}|[0-9]{2})[\\-/.\\s年]([0-9]{1,2})[\\-/.\\s月]([0-9]{1,2})日?",
            // Day-Month-Year structure: dd/MM/yyyy, d-M-yy, etc.
            "([0-9]{1,2})[\\-/.\\s月]([0-9]{1,2})[\\-/.\\s年]([0-9]{4}|[0-9]{2})",
            // Continuous digits: yyyyMMdd (8 digits) or yyMMdd (6 digits)
            "\\b([0-9]{8}|[0-9]{6})\\b"
        ]
        
        var candidates: [String] = []
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsString = cleanText as NSString
                let results = regex.matches(in: cleanText, options: [], range: NSRange(location: 0, length: nsString.length))
                for result in results {
                    candidates.append(nsString.substring(with: result.range))
                }
            }
        }
        
        // Add basic fallback where we just clean headers/colons
        let basicClean = cleanText
            .replacingOccurrences(of: "EXP", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "：", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespaces)
        candidates.append(basicClean)
        
        // 2. Comprehensive formats to check
        let formats = [
            // Year First
            "yyyy/MM/dd", "yyyy-MM-dd", "yyyy.MM.dd", "yyyy MM dd", "yyyy年MM月dd日",
            "yyyy/M/d", "yyyy-M-d", "yyyy.M.d", "yyyy年M月d日",
            "yy/MM/dd", "yy-MM-dd", "yy.MM.dd", "yy MM dd",
            "yy/M/d", "yy-M-d", "yy.M.d",
            "yyyyMMdd", "yyMMdd",
            
            // Day First
            "dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy", "dd MM yyyy",
            "d/M/yyyy", "d-M-yyyy", "d.M.yyyy",
            "dd/MM/yy", "dd-MM-yy", "dd.MM.yy",
            "d/M/yy", "d-M-yy", "d.M.yy"
        ]
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        for candidate in candidates {
            // Clean common punctuation from the extracted candidate
            let normalized = candidate
                .replacingOccurrences(of: "：", with: "")
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: normalized) {
                    // Sanity check: Date shouldn't be too far in past or future
                    let year = Calendar.current.component(.year, from: date)
                    if year > 2000 && year < 2100 {
                        return date
                    }
                }
            }
        }
        
        return nil
    }
}
