//
//  BrandAbsorptionProfile.swift
//  nicnark-2
//
//  Brand-specific systemic absorption fractions (share of *labeled* mg modeled
//  as reaching the bloodstream at full timer). Replaces the flat 0.30 average
//  when a pouch is tied to a known can brand.
//
//  These are calibrated estimates from published PK / extraction / dissolution /
//  permeability data — not lab-certified personal blood levels. Unknown brands
//  keep ABSORPTION_FRACTION (0.30).
//

import Foundation

public enum BrandAbsorptionProfile: String, CaseIterable, Sendable {
    case zyn
    case zynUltra
    case velo
    case veloPlus
    case fre
    case alp
    case clue
    case onClassic
    case onPlus
    case unknown

    /// Fraction of labeled mg modeled as systemically delivered at full timer.
    public var fraction: Double {
        switch self {
        case .zyn:        return 0.38   // dry mini; ~56–59% extraction (Lunell 2020); high pH / freebase
        case .zynUltra:   return 0.32   // moist slim; lower % extraction of label (~41% of 9 mg) but faster onset
        case .velo:       return 0.24   // dry US Velo; slower dissolution + ~2.6× lower buccal P_app vs Zyn
        case .veloPlus:   return 0.30   // moist slim Plus; better extraction than dry Velo, still below Zyn
        case .fre:        return 0.36   // dry-format US pouch, Zyn-class geometry; no published PK
        case .alp:        return 0.34   // dry-format US pouch; no published PK
        case .clue:       return 0.33   // newer US brand; no published PK — mid dry-format estimate
        case .onClassic:  return 0.42   // mini dry; very high freebase / pH; fastest dissolution class with Zyn
        case .onPlus:     return 0.34   // moist NICOSILK slim; PBPK tissue uptake ~0.35–0.38
        case .unknown:    return ABSORPTION_FRACTION
        }
    }

    public var displayName: String {
        switch self {
        case .zyn: return "Zyn"
        case .zynUltra: return "Zyn Ultra"
        case .velo: return "Velo"
        case .veloPlus: return "Velo Plus"
        case .fre: return "FRE"
        case .alp: return "ALP"
        case .clue: return "CLUE"
        case .onClassic: return "On!"
        case .onPlus: return "On! Plus"
        case .unknown: return "Unknown"
        }
    }

    /// Resolve a free-text can brand (case / punctuation insensitive).
    public static func resolve(brand: String?) -> BrandAbsorptionProfile {
        guard let raw = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        let key = normalize(raw)

        // Most-specific tokens first so "Zyn Ultra" ≠ "Zyn".
        if matches(key, ["zyn ultra", "zynultra"]) { return .zynUltra }
        if matches(key, ["velo plus", "veloplus", "velo+"]) { return .veloPlus }
        if matches(key, ["on plus", "on! plus", "onplus", "on!plus", "on!+"]) { return .onPlus }
        if key == "zyn" || key.hasPrefix("zyn ") { return .zyn }
        if key == "velo" || key.hasPrefix("velo ") { return .velo }
        if key == "fre" || key.hasPrefix("fre ") { return .fre }
        if key == "alp" || key.hasPrefix("alp ") { return .alp }
        if key == "clue" || key.hasPrefix("clue ") { return .clue }
        if key == "on" || key == "on!" || key.hasPrefix("on ") || key.hasPrefix("on! ") {
            return .onClassic
        }
        return .unknown
    }

    public static func fraction(forBrand brand: String?) -> Double {
        resolve(brand: brand).fraction
    }

    private static func normalize(_ s: String) -> String {
        var mapped = s.lowercased()
        mapped = mapped.replacingOccurrences(of: "®", with: "")
        mapped = mapped.replacingOccurrences(of: "™", with: "")
        mapped = mapped.replacingOccurrences(of: "+", with: " plus ")
        mapped = mapped.replacingOccurrences(of: "-", with: " ")
        mapped = mapped.replacingOccurrences(of: "_", with: " ")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "! "))
        let cleaned = String(mapped.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        return cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    private static func matches(_ key: String, _ needles: [String]) -> Bool {
        needles.contains { key == $0 || key.hasPrefix($0 + " ") || key.contains(" " + $0 + " ") || key.hasSuffix(" " + $0) }
    }
}
