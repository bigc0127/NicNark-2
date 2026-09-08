//
//  PouchLog+Can.swift
//  nicnark-2
//

import Foundation
import CoreData

extension PouchLog {
    /// Brand-profile cap of labeled mg. Unknown / no-can pouches stay at 0.30.
    var absorptionFraction: Double {
        BrandAbsorptionProfile.fraction(forBrand: can?.brand)
    }
}
