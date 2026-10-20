import Foundation
import Store

/// What a posting's required sentences say about work authorization, clearance, residency and
/// French. Each reads folded sentences from `TextScan.requiredSentences`, so "French is an asset"
/// or "clearance is a plus" never count.
enum Signals {
    struct AuthorizationNeed: Equatable {
        enum Kind { case noSponsorship, authorization, citizenship }
        let kind: Kind
        /// The country the sentence names; nil means the job's own.
        let country: Country?
    }

    enum ClearanceNeed: Equatable {
        /// An active clearance, now.
        case hold
        /// One you'd have to get, in the named country (nil: the job's).
        case obtain(Country?)
    }

    static func authorizationNeeds(_ sentences: [String]) -> [AuthorizationNeed] {
        let noSponsorship = [
            #/\b(?:no|not|unable to|cannot|can't|can not|will not|won't|do not|does not|not able to)\b[^.]{0,40}?\bsponsor/#,
            #/\bsponsorship\b[^.]{0,30}?\b(?:not|unavailable|no longer)\b/#,
            #/\bwithout\b[^.]{0,50}?\bsponsorship\b/#, #/\b(?:aucun|sans|pas de)\s+parrainage\b/#,
        ]
        let authorized =
            #/\b(?:authori[sz]ed|eligible|entitled|permitted|legally able)\s+to\s+work\s+in\s+(?:the\s+)?(?<country>u\.s\.?|usa|us|united states|america|canada)(?![a-z])/#
        let citizen = #/(?<country>u\.s\.?|usa|us|united states|american|canadian)\s+citizen(?:s|ship)?(?![a-z])/#
        var needs: [AuthorizationNeed] = []
        for sentence in sentences {
            if noSponsorship.contains(where: { sentence.contains($0) }) {
                needs.append(AuthorizationNeed(kind: .noSponsorship, country: nil))
            }
            if let match = sentence.firstMatch(of: authorized) {
                needs.append(AuthorizationNeed(kind: .authorization, country: country(match.output.country)))
            } else if sentence.contains(#/autorise(?:e|s|es)?\s+a\s+travailler\s+au\s+canada/#) {
                needs.append(AuthorizationNeed(kind: .authorization, country: .canada))
            }
            if let match = sentence.firstMatch(of: citizen),
                TextScan.containsAny(sentence, ["must", "required", "only"])
            {
                needs.append(AuthorizationNeed(kind: .citizenship, country: country(match.output.country)))
            }
        }
        return needs
    }

    static func clearanceNeeds(_ sentences: [String]) -> [ClearanceNeed] {
        let obtain =
            #/\b(?:able|ability|eligible|eligibility)\s+to\s+(?:obtain|get|acquire|be granted)\b[^.]{0,60}?\b(?:clearance|reliability status|security status)\b/#
        let hold = [
            #/\bts\/sci\b/#, #/\b(?:top secret|secret|public trust)\b[^.]{0,20}?\bclearance\b/#,
            #/\b(?:active|current|existing|valid)\b[^.]{0,30}?\b(?:clearance|reliability status)\b/#,
            #/\bclearance\b[^.]{0,30}?\b(?:required|needed|mandatory)\b/#,
            #/\b(?:must|required to)\s+(?:hold|have|possess|maintain)\b[^.]{0,40}?\b(?:clearance|reliability status)\b/#,
        ]
        var needs: [ClearanceNeed] = []
        for sentence in sentences {
            if TextScan.containsAny(sentence, ["no security clearance", "no clearance", "not require", "not required"])
            {
                continue
            }
            if sentence.contains(obtain) {
                let canadian = TextScan.containsAny(sentence, ["reliability status", "canada", "canadian"])
                let american = TextScan.containsAny(sentence, ["u.s", "united states", "american", "us government"])
                needs.append(.obtain(canadian ? .canada : american ? .unitedStates : nil))
            } else if hold.contains(where: { sentence.contains($0) }) {
                needs.append(.hold)
            }
        }
        return needs
    }

    /// The country a remote posting requires you to live in ("Candidates must reside in the US").
    static func residencyCountry(_ sentences: [String]) -> Country? {
        let patterns = [
            #/\b(?:must|need to|needs to|required to|should|have to)\s+(?:be\s+)?(?:located|based|reside|residing|live|living|a resident)\s+(?:in|of)\s+(?:the\s+)?(?<country>u\.s\.?|usa|us|united states|canada)(?![a-z])/#,
            #/\b(?<country>u\.s\.?|usa|us|united states|canada)[- ]based\s+(?:candidates|applicants|residents)?\s*only\b/#,
            #/\bremote\s*[(-]?\s*(?<country>u\.s\.?|usa|us|united states|canada)\s+only\b/#,
        ]
        for sentence in sentences {
            for pattern in patterns {
                if let match = sentence.firstMatch(of: pattern) { return country(match.output.country) }
            }
        }
        return nil
    }

    /// French asked for: "bilingual" (in Canada that means English and French), or French with
    /// "required", "fluent", "maîtrise" and the like.
    static func requiresFrench(_ sentences: [String], country: Country?) -> Bool {
        let otherLanguages = [
            "spanish", "mandarin", "cantonese", "punjabi", "hindi", "portuguese", "german", "japanese", "korean",
            "arabic", "tagalog", "italian", "vietnamese",
        ]
        let required = [
            "required", "requis", "requise", "mandatory", "obligatoire", "essential", "essentiel", "essentielle",
            "exige",
            "exigee", "must", "fluent", "fluency", "proficient", "proficiency", "maitrise", "written and spoken",
            "spoken and written", "parle et ecrit",
        ]
        return sentences.contains { sentence in
            let french = TextScan.containsAny(sentence, ["french", "francais"])
            let bilingual = TextScan.containsAny(sentence, ["bilingual", "bilingue", "bilingualism", "bilinguisme"])
            if bilingual && (french || (country == .canada && !TextScan.containsAny(sentence, otherLanguages))) {
                return true
            }
            return french && TextScan.containsAny(sentence, required)
        }
    }

    private static func country(_ text: Substring) -> Country {
        text.hasPrefix("c") ? .canada : .unitedStates
    }
}
