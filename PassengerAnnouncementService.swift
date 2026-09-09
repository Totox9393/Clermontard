//
//  PassengerAnnouncementService.swift
//  Clermontard
//
//  Gestion des annonces voyageurs à partir des Data Assets de Assets.xcassets.
//

import Foundation
import AVFoundation
import UIKit

// MARK: - Réglage partagé

enum PassengerAnnouncementSettings {
    static let enabledKey = "passengerAnnouncementsEnabled"
}

// MARK: - Une direction à annoncer

struct PassengerAnnouncementItem {
    /// Nom de destination tel qu'il est fourni par T2C.
    let directionName: String

    /// Premier passage confirmé en temps réel.
    /// nil = aucun passage temps réel annoncé pour cette direction.
    let nextRealtimeDeparture: Date?
}

// MARK: - Service audio

final class PassengerAnnouncementService: NSObject, AVAudioPlayerDelegate {

    static let shared = PassengerAnnouncementService()

    private var player: AVAudioPlayer?
    private var pendingAudioData: [Data] = []

    private override init() {
        super.init()
    }

    // MARK: API publique

    /// Joue une annonce pour une ou plusieurs directions.
    ///
    /// Règles :
    /// - passage temps réel de 1 à 15 min :
    ///   dir_XXX_ProPassDans + Xmin
    /// - passage temps réel au-delà de 15 min :
    ///   aucune annonce
    /// - aucun passage pour une seule direction :
    ///   dir_XXX + aucun_passage
    /// - aucun passage pour toutes les directions affichées (2 ou plus) :
    ///   dir_XXX + dir_YYY + aucun_passages
    func announce(_ items: [PassengerAnnouncementItem]) {

        guard UserDefaults.standard.bool(
            forKey: PassengerAnnouncementSettings.enabledKey
        ) else {
            stop()
            return
        }

        let cleanedItems = items.filter {
            !$0.directionName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        guard !cleanedItems.isEmpty else {
            return
        }

        stop()

        var clips: [Data] = []

        let allDirectionsHaveNoRealtimePassage =
            cleanedItems.count > 1
            && cleanedItems.allSatisfy {
                $0.nextRealtimeDeparture == nil
            }

        // Cas particulier : deux directions (ou plus) sans aucun passage.
        // On annonce d'abord les directions, puis la phrase au pluriel une seule fois.
        if allDirectionsHaveNoRealtimePassage {

            for item in cleanedItems {
                if let data = directionOnlyClip(
                    for: item.directionName
                ) {
                    clips.append(data)
                }
            }

            if let noPassages = loadDataAsset(
                candidatesForCommonAsset("aucun_passages")
            ) {
                clips.append(noPassages)
            }

            startQueue(clips)
            return
        }

        // Cas normal : chaque direction est traitée indépendamment.
        for item in cleanedItems {

            if let departure = item.nextRealtimeDeparture {

                let minutes = announcedMinutes(
                    until: departure
                )

                // Au-delà de 15 min : volontairement aucune annonce.
                guard (1...15).contains(minutes) else {
                    continue
                }

                if let intro = nextPassageClip(
                    for: item.directionName
                ) {
                    clips.append(intro)
                } else {
                    // Sans l'intro de direction, on ne joue pas une minute isolée.
                    debugMissing(
                        "annonce prochain passage",
                        direction: item.directionName
                    )
                    continue
                }

                if let minuteClip = loadDataAsset(
                    candidatesForMinute(minutes)
                ) {
                    clips.append(minuteClip)
                } else {
                    debugMissing(
                        "\(minutes)min",
                        direction: item.directionName
                    )
                }

            } else {

                // Une direction précise sans passage.
                if let directionClip = directionOnlyClip(
                    for: item.directionName
                ) {
                    clips.append(directionClip)

                    if let noPassage = loadDataAsset(
                        candidatesForCommonAsset("aucun_passage")
                    ) {
                        clips.append(noPassage)
                    }
                } else {
                    debugMissing(
                        "annonce de direction",
                        direction: item.directionName
                    )
                }
            }
        }

        startQueue(clips)
    }

    /// Arrête immédiatement l'annonce en cours et vide la file.
    func stop() {

        pendingAudioData.removeAll()

        player?.stop()
        player = nil

        deactivateAudioSession()
    }

    // MARK: Lecture séquentielle

    private func startQueue(_ clips: [Data]) {

        guard !clips.isEmpty else {
            return
        }

        pendingAudioData = clips

        configureAudioSession()
        playNext()
    }

    private func playNext() {

        guard !pendingAudioData.isEmpty else {

            player = nil
            deactivateAudioSession()
            return
        }

        let data = pendingAudioData.removeFirst()

        do {
            let audioPlayer = try AVAudioPlayer(data: data)

            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()

            player = audioPlayer
            audioPlayer.play()

        } catch {
            print("🔊 ClermonTard : impossible de lire un son : \(error.localizedDescription)")
            playNext()
        }
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        playNext()
    }

    func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        self.player = nil

        if let error {
            print("🔊 ClermonTard : erreur de décodage audio : \(error.localizedDescription)")
        }

        playNext()
    }

    // MARK: Construction des annonces

    private func directionOnlyClip(
        for direction: String
    ) -> Data? {

        for base in directionAssetBases(
            for: direction
        ) {
            let assetName = "dir_\(base)"

            if let data = loadDataAsset(
                candidatesForDirectionAsset(assetName)
            ) {
                return data
            }
        }

        return nil
    }

    private func nextPassageClip(
        for direction: String
    ) -> Data? {

        for base in directionAssetBases(
            for: direction
        ) {

            // Tes assets ne sont pas tous nommés exactement pareil :
            // la capture montre notamment _ProPassDans et _ProPassageDans.
            let names = [
                "dir_\(base)_ProPassDans",
                "dir_\(base)_ProPassageDans",
                "dir_\(base)_ProchainPassageDans"
            ]

            for name in names {

                if let data = loadDataAsset(
                    candidatesForDirectionAsset(name)
                ) {
                    return data
                }
            }
        }

        return nil
    }

    // MARK: Correspondance destination T2C -> nom d'asset

    private func directionAssetBases(
        for direction: String
    ) -> [String] {

        let normalized = normalize(direction)

        // Exceptions connues d'après tes fichiers actuels.
        // Tu peux ajouter ici une destination si le nom T2C ne correspond
        // pas naturellement au nom de ton Data Asset.
        let aliases: [String: String] = [
            // MARK: Lignes A / B / C déjà présentes

            "aulnatstexupery": "AulnatStExp",
            "aulnatstexp": "AulnatStExp",
            "aulnatsaintexupery": "AulnatStExp",

            "cournonallier": "CournonAllier",
            "cournondauvergneallier": "CournonAllier",

            "durtolclinique": "DurtolClinique",

            "lapardieugare": "LaPardieuGare",

            "lesvergnes": "LesVergnes",

            "julesverne": "JulesVerne",
            "clermontjulesverne": "JulesVerne",
            "clermontferrandjulesverne": "JulesVerne",

            "royatallard": "RoyatAllard",
            "royatplallard": "RoyatAllard",
            "royatplaceallard": "RoyatAllard",

            // MARK: Nouvelles destinations / terminus E
            //
            // Important : le mapping dépend uniquement du nom de destination,
            // pas de la ligne. Si plusieurs lignes ont le même terminus,
            // le même fichier audio sera donc réutilisé automatiquement.

            "chamalieresaristidebriand": "ChamalieresAristideBriand",

            // Le fichier que tu as créé s'appelle exactement RoyatAvanCBreuil.
            // On accepte plusieurs variantes possibles du libellé T2C.
            "royatavcbreuil": "RoyatAvanCBreuil",
            "royatavancbreuil": "RoyatAvanCBreuil",
            "royatavenuecbreuil": "RoyatAvanCBreuil",
            "royatavenuecharlesbreuil": "RoyatAvanCBreuil",

            "gaillard": "Gaillard",

            "romagnatgergovia": "RomagnatGergovia",
            "romagnatopme": "RomagnatOpme",
            "romagnatlagazelle": "RomagnatLaGazelle",

            "faculte": "Faculte",

            // Ton asset utilise "Pontdu..." et non "PontDu..."
            "pontduchateauchambonhaut": "PontduChateauChambonHaut",

            "lempdeslepontel": "LempdesLePontel",
            "lempdeslarochelle": "LempdesLaRochelle",

            "tremonteixpauleychart": "TremonteixPaulEychart",
            "tremonteixcharcot": "TremonteixCharcot",

            "lyceelafayette": "LyceeLafayette",
            "lyceelafayetteclermont": "LyceeLafayette",

            // T2C utilise notamment "CEBAZAT CHU L. Michel"
            "cebazatchulmichel": "CebazatCHULouiseMichel",
            "cebazatchulouisemichel": "CebazatCHULouiseMichel",

            "lesvignes": "LesVignes",

            // T2C peut renvoyer "AUBIÈRE Pl. des Ramacles"
            "aubierepldesramacles": "AubierePlaceRamacles",
            "aubiereplacedesramacles": "AubierePlaceRamacles",
            "aubiereplaceramacles": "AubierePlaceRamacles",

            "gerzatchampfleuri": "GerzatChampfleuri",

            // "1er Mai" et "Premier Mai" utilisent le même son.
            "1ermai": "PremierMai",
            "premiermai": "PremierMai",

            "beaumontpontdeboissejour": "BeaumontPontDeBoissejour",
            "beaumontpontboissejour": "BeaumontPontDeBoissejour",

            "ceyratliberation": "CeyratLiberation",
            
            "europevge": "EuropeVGE",
            "chamaliereseuropevge": "EuropeVGE",
            "europevalerygiscarddestaing": "EuropeVGE",
            "chamaliereseuropevalerygiscarddestaing": "EuropeVGE"
        ]

        var candidates: [String] = []

        if let alias = aliases[normalized] {
            candidates.append(alias)
        }

        let generated = generatedAssetBase(
            from: direction
        )

        if !generated.isEmpty,
           !candidates.contains(generated) {
            candidates.append(generated)
        }

        return candidates
    }

    /// Transforme par exemple :
    /// "La Pardieu Gare" -> "LaPardieuGare"
    /// "Les Vergnes" -> "LesVergnes"
    private func generatedAssetBase(
        from text: String
    ) -> String {

        let folded = text.folding(
            options: [
                .diacriticInsensitive,
                .caseInsensitive
            ],
            locale: Locale(identifier: "fr_FR")
        )

        let words = folded
            .components(
                separatedBy:
                    CharacterSet.alphanumerics.inverted
            )
            .filter {
                !$0.isEmpty
            }

        return words.map { word in

            guard let first = word.first else {
                return ""
            }

            return String(first).uppercased()
                + word.dropFirst().lowercased()

        }.joined()
    }

    private func normalize(
        _ text: String
    ) -> String {

        text
            .folding(
                options: [
                    .diacriticInsensitive,
                    .caseInsensitive
                ],
                locale: Locale(identifier: "fr_FR")
            )
            .lowercased()
            .components(
                separatedBy:
                    CharacterSet.alphanumerics.inverted
            )
            .joined()
    }

    // MARK: Minutes

    private func announcedMinutes(
        until date: Date
    ) -> Int {

        let seconds =
            date.timeIntervalSinceNow

        // Si le véhicule est à moins d'une minute,
        // on utilise le fichier "1min".
        return max(
            1,
            Int(
                ceil(
                    seconds / 60
                )
            )
        )
    }

    // MARK: Recherche dans Assets.xcassets

    private func candidatesForDirectionAsset(
        _ assetName: String
    ) -> [String] {

        [
            assetName,
            "annonces_voy/\(assetName)"
        ]
    }

    private func candidatesForMinute(
        _ minute: Int
    ) -> [String] {

        let name = "\(minute)min"

        return [
            name,
            "compteur_min/\(name)",
            "annonces_voy/\(name)",
            "annonces_voy/compteur_min/\(name)"
        ]
    }

    private func candidatesForCommonAsset(
        _ assetName: String
    ) -> [String] {

        [
            assetName,
            "annonces_voy/\(assetName)"
        ]
    }

    private func loadDataAsset(
        _ names: [String]
    ) -> Data? {

        for name in names {

            if let asset = NSDataAsset(
                name: name
            ) {
                return asset.data
            }
        }

        print(
            "🔊 ClermonTard : Data Asset introuvable parmi : \(names.joined(separator: ", "))"
        )

        return nil
    }

    private func debugMissing(
        _ type: String,
        direction: String
    ) {
        print(
            "🔊 ClermonTard : \(type) introuvable pour « \(direction) »."
        )
    }

    // MARK: Session audio

    private func configureAudioSession() {

        let session =
            AVAudioSession.sharedInstance()

        do {
            // .playback permet à une annonce explicitement activée
            // d'être audible comme une vraie annonce voyageurs.
            // duckOthers baisse temporairement le volume d'une musique en cours.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )

            try session.setActive(true)

        } catch {
            print(
                "🔊 ClermonTard : impossible d'activer la session audio : \(error.localizedDescription)"
            )
        }
    }

    private func deactivateAudioSession() {

        let session =
            AVAudioSession.sharedInstance()

        do {
            try session.setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            // Ne bloque jamais l'application pour une erreur de désactivation audio.
        }
    }
}
