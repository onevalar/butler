//
//  NLPParser.swift
//  Butler
//
//  Created by 安宇佳 on 2026/1/6.
//

import Foundation
import NaturalLanguage

// MARK: - Parser Result

struct ParsedVoiceResult: Sendable {
    let items: [ParsedItemInput]
    let originalText: String
}

// MARK: - NLP Parser

/// The "Brain" of the voice system.
/// Uses on-device Natural Language framework to extract intent and entities.
actor NLPParser {
    
    // MARK: - Properties
    
    private let tagger: NLTagger
    
    // Knowledge base for keyword matching (simplified for demo)
    // In a real production app, this would be a CoreML model or extensive dictionary
    private let foodKeywords: Set<String> = ["牛奶", "肉", "菜", "蛋", "面包", "果", "鱼", "虾", "米", "油", "盐", "酱", "醋", "茶", "鸡", "鸭", "牛", "羊", "猪"]
    private let medicineKeywords: Set<String> = ["药", "片", "胶囊", "丸", "散", "素", "医"]
    private let quantifierKeywords: Set<String> = ["个", "只", "把", "箱", "袋", "盒", "包", "瓶", "罐", "斤", "公斤", "两", "支", "条"]
    
    // MARK: - Initialization
    
    init() {
        // We configure the tagger to look for all standard schemes
        self.tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .tokenType])
    }
    
    // MARK: - Parsing Logic
    
    /// Main entry point: Parse raw text into structured item inputs
    func parse(_ text: String) -> ParsedVoiceResult {
        let items = extractItems(from: text)
        return ParsedVoiceResult(items: items, originalText: text)
    }
    
    /// Core logic: Extract [Quantity + Name] pairs
    private func extractItems(from text: String) -> [ParsedItemInput] {
        var results: [ParsedItemInput] = []
        
        // 1. Initial Cleanup
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tagger.string = cleanText
        
        // 2. Tokenize and analyze
        // Strategy: Iterate through tokens, look for Number+Quantifier patterns followed by Nouns
        // This is a heuristic approach suitable for "Grocery List" style speech
        
        var pendingQuantity: Int? = nil
        var pendingUnit: String? = nil

        // enumerateTags allows us to walk through the sentence
        tagger.enumerateTags(in: cleanText.startIndex..<cleanText.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, tokenRange in
            let word = String(cleanText[tokenRange])

            // --- Logic Block A: Quantity Detection ---
            if let number = parseNumber(word) {
                pendingQuantity = number
                return true
            }

            // --- Logic Block B: Quantifier Capture (e.g., "3个", "三瓶") ---
            // Store the quantifier word as unit and skip to next token
            if isQuantifier(word) {
                pendingUnit = word
                return true
            }

            // --- Logic Block C: Noun/Item Detection ---
            // NLTagger isn't perfect with Chinese generic nouns without context.
            // We use a combination of POS tagging (.noun) and our heuristic keywords.

            let isNoun = tag == .noun || tag == .otherWord
            let isHeuristicMatch = containsKeyword(word)

            if (isNoun || isHeuristicMatch) && !isVerb(word, tag: tag) {
                // FOUND AN ITEM!

                let quantity = pendingQuantity ?? 1
                let type = guessType(for: word)

                let input = ParsedItemInput(
                    name: word,
                    quantity: quantity,
                    unit: pendingUnit,
                    suggestedType: type,
                    expiryDate: nil,
                    storageHint: detectStorageHint(in: cleanText),
                    confidence: 0.8
                )

                results.append(input)

                // Reset state
                pendingQuantity = nil
                pendingUnit = nil
            }

            return true
        }
        
        // Fallback: If NLP failed to find anything but text exists, treat the whole thing as one item
        // e.g. "奥利奥" might not be tagged as noun
        if results.isEmpty && !cleanText.isEmpty {
            let type = guessType(for: cleanText)
            results.append(ParsedItemInput(
                name: cleanText,
                quantity: 1,
                unit: nil,
                suggestedType: type,
                expiryDate: nil,
                storageHint: nil,
                confidence: 0.5
            ))
        }
        
        return results
    }
    
    // MARK: - Helpers
    
    private func parseNumber(_ word: String) -> Int? {
        // Arabic numerals
        if let intVal = Int(word) { return intVal }
        
        // Chinese numerals (simplified)
        let cnNumbers: [String: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, 
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        return cnNumbers[word]
    }
    
    private func isQuantifier(_ word: String) -> Bool {
        quantifierKeywords.contains { word.contains($0) }
    }
    
    private func isVerb(_ word: String, tag: NLTag?) -> Bool {
        return tag == .verb || ["买", "购买", "放入", "有"].contains(word)
    }
    
    private func containsKeyword(_ word: String) -> Bool {
        // Check if word contains any of our known food/med keywords
        foodKeywords.contains { word.contains($0) } || medicineKeywords.contains { word.contains($0) }
    }
    
    private func guessType(for name: String) -> ItemType {
        let n = name.lowercased()
        
        // Rule-based classification
        if medicineKeywords.contains(where: { n.contains($0) }) {
            return .medicine
        }
        
        // High probability fresh keywords
        let freshKeys = ["肉", "鱼", "蛋", "菜", "奶", "果", "葱", "姜", "蒜"]
        if freshKeys.contains(where: { n.contains($0) }) {
            return .fresh
        }
        
        // Default based on length or other heuristics could go here
        // For now, default to pantry if nothing else matches, or general
        return .general
    }
    
    private func detectStorageHint(in text: String) -> String? {
        if text.contains("冷冻") || text.contains("冻起来") { return "冷冻" }
        if text.contains("冷藏") || text.contains("冰箱") { return "冷藏" }
        return nil
    }
}
