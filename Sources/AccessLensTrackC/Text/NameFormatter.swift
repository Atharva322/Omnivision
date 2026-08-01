//
//  NameFormatter.swift
//  Track C — repairing the casing of a name lifted from a transcript.
//

import Foundation

/// Repairs capitalisation on a name lifted from an ASR transcript, without destroying one that
/// already had it. Transcripts arrive both fully lowercased and properly cased, and "MCKENZIE"
/// happens too.
public enum NameFormatter {

    public static func display(_ surface: String) -> String {
        guard !surface.isEmpty else { return surface }

        // Already mixed case ("McKenzie", "DeSilva") — the recogniser knew something we do not.
        let hasInteriorUppercase = surface.dropFirst().contains { $0.isUppercase }
        let isAllUppercase = surface.allSatisfy { !$0.isLetter || $0.isUppercase }
        if hasInteriorUppercase && !isAllUppercase {
            return capitalizeFirstLetter(surface)
        }

        var result = ""
        var capitalizeNext = true
        for character in surface.lowercased() {
            if capitalizeNext, character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                capitalizeNext = false
            } else {
                result.append(character)
                // Split points inside real names: "Jean-Luc", "O'Brien".
                if character == "-" || character == "'" || character == "\u{2019}" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }

    private static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
