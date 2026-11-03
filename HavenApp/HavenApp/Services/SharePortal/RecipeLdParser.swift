import Foundation

/// A shared recipe page → the recipe composer's draft fields (§6.2).
struct RecipeLdParser {
    struct Fields: Equatable {
        var title = ""
        var summary = ""
        var prepTime = ""
        var cookTime = ""
        var servings = ""
        var ingredients = ""
        var directions = ""
        var categories = ""
        var body = ""
    }

    static func parse(html: String, pageTitle: String?, url: String?) -> Fields {
        guard let r = ShareLinkedData.first("Recipe", in: html) else {
            let t = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = t.isEmpty ? (url.flatMap(NVShareClassifier.host(of:)) ?? "") : t
            return Fields(title: t, body: ArticleClipDraft.sourceLine(label: label, url: url))
        }
        var f = Fields()
        f.title = (r["name"] as? String).map(ShareLinkedData.clean)
            ?? pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        f.summary = ShareLinkedData.text(r, "description")
        f.prepTime = (r["prepTime"] as? String).map(duration) ?? ""
        f.cookTime = (r["cookTime"] as? String).map(duration) ?? ""
        f.servings = servings(r["recipeYield"])
        f.ingredients = ShareLinkedData.strings(r["recipeIngredient"]).map(ShareLinkedData.clean)
            .filter { !$0.isEmpty }.joined(separator: "\n")
        f.directions = steps(r["recipeInstructions"]).joined(separator: "\n")
        var seen = Set<String>()
        var cats: [String] = []
        for v in ShareLinkedData.strings(r["recipeCategory"]) + ShareLinkedData.strings(r["recipeCuisine"]) {
            for part in v.split(separator: ",", omittingEmptySubsequences: false) {
                let c = ShareLinkedData.clean(String(part))
                if !c.isEmpty, seen.insert(c.lowercased()).inserted { cats.append(c) }
            }
        }
        f.categories = cats.joined(separator: ", ")
        f.body = ArticleClipDraft.sourceLine(label: f.title, url: url)
        return f
    }

    private static func servings(_ value: Any?) -> String {
        var v = value
        if let list = v as? [Any] { v = list.first }
        if let s = v as? String { return ShareLinkedData.clean(s) }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return ""
    }

    static func steps(_ value: Any?) -> [String] {
        if let s = value as? String {
            return s.components(separatedBy: "\n").map(ShareLinkedData.clean).filter { !$0.isEmpty }
        }
        var list: [Any] = []
        if let d = value as? [String: Any] { list = [d] } else if let l = value as? [Any] { list = l }
        var out: [String] = []
        for item in list {
            if let s = item as? String {
                let c = ShareLinkedData.clean(s)
                if !c.isEmpty { out.append(c) }
            } else if let d = item as? [String: Any] {
                if ShareLinkedData.types(d).contains("HowToSection") {
                    out += steps(d["itemListElement"] ?? [Any]())
                } else {
                    let t = (d["text"] as? String) ?? (d["name"] as? String) ?? ""
                    let c = ShareLinkedData.clean(t)
                    if !c.isEmpty { out.append(c) }
                }
            }
        }
        return out
    }

    /// `PT1H30M` → `1 h 30 min`. Anything that is not a whole-number ISO
    /// 8601 duration is kept as given.
    static func duration(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard s != "P", s != "PT", let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return s }
        func group(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: s) else { return 0 }
            return Int(s[r]) ?? 0
        }
        let hours = group(1) * 24 + group(2)
        let mins = group(3)
        var out: [String] = []
        if hours > 0 { out.append("\(hours) h") }
        if mins > 0 { out.append("\(mins) min") }
        return out.joined(separator: " ")
    }
}
