// mTAPES — textes de l'interface (français d'abord, puis anglais, espagnol, italien ; mêmes clés dans chaque table).
import Foundation

enum L {
    /// Forcer une langue (essais : --lang fr|en|es|it).
    nonisolated(unsafe) static var override: String?

    /// Langue du système si elle fait partie des quatre, sinon l'anglais.
    static var lang: String {
        if let o = override, tables[o] != nil { return o }
        let code = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        return tables[code] != nil ? code : "en"
    }
    static var locale: Locale { Locale(identifier: lang) }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let s = tables[lang]?[key] ?? tables["en"]?[key] ?? key
        return args.isEmpty ? s : String(format: s, locale: locale, arguments: args)
    }

    static let tables: [String: [String: String]] = ["fr": fr, "en": en, "es": es, "it": it]

    private static let fr: [String: String] = [
        "app.tagline": "Enregistre votre écran avec soin : net, léger et silencieux.",
        "menu.open": "Ouvrir mTAPES", "menu.record": "Enregistrer", "menu.stop": "Arrêter et finir",
        "menu.about": "À propos de mTAPES", "menu.quit": "Quitter mTAPES",
        "main.what": "Que voulez-vous filmer ?",
        "target.screen": "Tout l'écran", "target.window": "Une fenêtre", "target.zone": "Une zone",
        "target.zone.soon": "Bientôt", "target.window.none": "Aucune fenêtre ouverte",
        "target.window.pick": "Fenêtre à filmer", "target.window.refresh": "Actualiser",
        "btn.record": "Enregistrer", "btn.stop": "Arrêter", "btn.again": "Recommencer", "btn.reveal": "Afficher dans le Finder",
        "btn.retry": "Réessayer", "btn.perm.open": "Ouvrir les Réglages Système", "btn.perm.recheck": "Vérifier à nouveau",
        "hint.record": "Raccourci %@. mTAPES n'apparaît jamais dans la vidéo.",
        "perm.title": "Autorisation nécessaire",
        "perm.body": "Pour filmer, macOS demande votre accord : Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran, puis cochez mTAPES. Rien n'est filmé tant que vous n'appuyez pas sur Enregistrer.",
        "rec.title": "Enregistrement en cours",
        "rec.screen": "Tout l'écran", "rec.window": "Fenêtre : %@",
        "rec.hint": "Faites votre démonstration comme d'habitude, puis arrêtez.",
        "fin.title": "Finalisation de la prise…",
        "done.title": "Votre prise est prête",
        "done.stats": "%@ · %@ · %d images",
        "done.note": "Le montage automatique (zooms, curseur, export) arrive à la prochaine étape : pour l'instant, la prise brute est enregistrée telle quelle.",
        "done.where": "Enregistrée dans %@",
        "err.title": "L'enregistrement a échoué",
        "about.menu": "À propos de mTAPES", "about.version": "Version %@ (%@)",
        "about.tagline": "Enregistre votre écran avec soin : net, léger et silencieux.",
        "about.collection": "Fait partie du",
        "about.authors": "Starbudweiser & Claude Code (Anthropic)", "about.license": "Licence MIT. © 2026 Starbudweiser.",
        "about.disclaimer": "Fourni en l'état, sans garantie.",
    ]

    private static let en: [String: String] = [
        "app.tagline": "Records your screen with care: sharp, light and silent.",
        "menu.open": "Open mTAPES", "menu.record": "Record", "menu.stop": "Stop and finish",
        "menu.about": "About mTAPES", "menu.quit": "Quit mTAPES",
        "main.what": "What do you want to film?",
        "target.screen": "The whole screen", "target.window": "A window", "target.zone": "A zone",
        "target.zone.soon": "Coming soon", "target.window.none": "No open window",
        "target.window.pick": "Window to film", "target.window.refresh": "Refresh",
        "btn.record": "Record", "btn.stop": "Stop", "btn.again": "Start over", "btn.reveal": "Show in Finder",
        "btn.retry": "Try again", "btn.perm.open": "Open System Settings", "btn.perm.recheck": "Check again",
        "hint.record": "Shortcut %@. mTAPES never appears in the video.",
        "perm.title": "Permission needed",
        "perm.body": "To film, macOS asks for your consent: System Settings > Privacy & Security > Screen Recording, then tick mTAPES. Nothing is filmed until you press Record.",
        "rec.title": "Recording",
        "rec.screen": "The whole screen", "rec.window": "Window: %@",
        "rec.hint": "Do your demonstration as usual, then stop.",
        "fin.title": "Finishing the take…",
        "done.title": "Your take is ready",
        "done.stats": "%@ · %@ · %d frames",
        "done.note": "Automatic editing (zooms, cursor, export) comes in the next step: for now, the raw take is saved as is.",
        "done.where": "Saved in %@",
        "err.title": "Recording failed",
        "about.menu": "About mTAPES", "about.version": "Version %@ (%@)",
        "about.tagline": "Records your screen with care: sharp, light and silent.",
        "about.collection": "Part of the",
        "about.authors": "Starbudweiser & Claude Code (Anthropic)", "about.license": "MIT License. © 2026 Starbudweiser.",
        "about.disclaimer": "Provided as is, without warranty.",
    ]

    private static let es: [String: String] = [
        "app.tagline": "Graba tu pantalla con cuidado: nítida, ligera y silenciosa.",
        "menu.open": "Abrir mTAPES", "menu.record": "Grabar", "menu.stop": "Parar y terminar",
        "menu.about": "Acerca de mTAPES", "menu.quit": "Salir de mTAPES",
        "main.what": "¿Qué quieres grabar?",
        "target.screen": "Toda la pantalla", "target.window": "Una ventana", "target.zone": "Una zona",
        "target.zone.soon": "Próximamente", "target.window.none": "Ninguna ventana abierta",
        "target.window.pick": "Ventana a grabar", "target.window.refresh": "Actualizar",
        "btn.record": "Grabar", "btn.stop": "Parar", "btn.again": "Empezar de nuevo", "btn.reveal": "Mostrar en el Finder",
        "btn.retry": "Reintentar", "btn.perm.open": "Abrir Ajustes del Sistema", "btn.perm.recheck": "Comprobar de nuevo",
        "hint.record": "Atajo %@. mTAPES nunca aparece en el vídeo.",
        "perm.title": "Permiso necesario",
        "perm.body": "Para grabar, macOS pide tu consentimiento: Ajustes del Sistema > Privacidad y seguridad > Grabación de pantalla, y marca mTAPES. No se graba nada hasta que pulses Grabar.",
        "rec.title": "Grabando",
        "rec.screen": "Toda la pantalla", "rec.window": "Ventana: %@",
        "rec.hint": "Haz tu demostración como de costumbre y luego para.",
        "fin.title": "Finalizando la toma…",
        "done.title": "Tu toma está lista",
        "done.stats": "%@ · %@ · %d imágenes",
        "done.note": "El montaje automático (zooms, cursor, exportación) llega en la próxima etapa: por ahora, la toma en bruto se guarda tal cual.",
        "done.where": "Guardada en %@",
        "err.title": "La grabación ha fallado",
        "about.menu": "Acerca de mTAPES", "about.version": "Versión %@ (%@)",
        "about.tagline": "Graba tu pantalla con cuidado: nítida, ligera y silenciosa.",
        "about.collection": "Forma parte del",
        "about.authors": "Starbudweiser & Claude Code (Anthropic)", "about.license": "Licencia MIT. © 2026 Starbudweiser.",
        "about.disclaimer": "Se ofrece tal cual, sin garantía.",
    ]

    private static let it: [String: String] = [
        "app.tagline": "Registra lo schermo con cura: nitido, leggero e silenzioso.",
        "menu.open": "Apri mTAPES", "menu.record": "Registra", "menu.stop": "Ferma e finisci",
        "menu.about": "Informazioni su mTAPES", "menu.quit": "Esci da mTAPES",
        "main.what": "Cosa vuoi riprendere?",
        "target.screen": "Tutto lo schermo", "target.window": "Una finestra", "target.zone": "Una zona",
        "target.zone.soon": "Presto", "target.window.none": "Nessuna finestra aperta",
        "target.window.pick": "Finestra da riprendere", "target.window.refresh": "Aggiorna",
        "btn.record": "Registra", "btn.stop": "Ferma", "btn.again": "Ricomincia", "btn.reveal": "Mostra nel Finder",
        "btn.retry": "Riprova", "btn.perm.open": "Apri Impostazioni di Sistema", "btn.perm.recheck": "Controlla di nuovo",
        "hint.record": "Scorciatoia %@. mTAPES non compare mai nel video.",
        "perm.title": "Autorizzazione necessaria",
        "perm.body": "Per registrare, macOS chiede il tuo consenso: Impostazioni di Sistema > Privacy e sicurezza > Registrazione schermo, poi seleziona mTAPES. Non viene ripreso nulla finché non premi Registra.",
        "rec.title": "Registrazione in corso",
        "rec.screen": "Tutto lo schermo", "rec.window": "Finestra: %@",
        "rec.hint": "Fai la tua dimostrazione come al solito, poi ferma.",
        "fin.title": "Finalizzazione della ripresa…",
        "done.title": "La tua ripresa è pronta",
        "done.stats": "%@ · %@ · %d immagini",
        "done.note": "Il montaggio automatico (zoom, cursore, esportazione) arriva nella prossima fase: per ora la ripresa grezza viene salvata così com'è.",
        "done.where": "Salvata in %@",
        "err.title": "Registrazione non riuscita",
        "about.menu": "Informazioni su mTAPES", "about.version": "Versione %@ (%@)",
        "about.tagline": "Registra lo schermo con cura: nitido, leggero e silenzioso.",
        "about.collection": "Fa parte del",
        "about.authors": "Starbudweiser & Claude Code (Anthropic)", "about.license": "Licenza MIT. © 2026 Starbudweiser.",
        "about.disclaimer": "Fornito così com'è, senza garanzie.",
    ]
}
