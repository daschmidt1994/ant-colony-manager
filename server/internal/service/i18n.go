package service

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"github.com/google/uuid"
)

// Server texts (e-mail, ntfy, sensor problems) in the recipient's language.
// German is the source; enTexts translates it. Keys are fmt formats – the
// translation must use the same verbs (TestServerTranslations checks it).

var languages = map[string]bool{"de": true, "en": true}

var enTexts = map[string]string{
	// notifications
	"Pflege überfällig":    "Care overdue",
	"Morgen":               "Tomorrow",
	"Sensor-Alarm":         "Sensor alarm",
	"Winterruhe":           "Hibernation",
	"Winterruhe beginnen?": "Start hibernation?",
	"Winterruhe beenden?":  "End hibernation?",
	"Sensor „%s“: %s %s %s – über dem Grenzwert %s %s":  "Sensor “%s”: %s %s %s – above the limit %s %s",
	"Sensor „%s“: %s %s %s – unter dem Grenzwert %s %s": "Sensor “%s”: %s %s %s – below the limit %s %s",
	"Temperatur":               "Temperature",
	"Luftfeuchtigkeit":         "Humidity",
	"heute fällig":             "due today",
	"seit 1 Tag überfällig":    "overdue for 1 day",
	"seit %d Tagen überfällig": "overdue for %d days",
	"Fütterung":                "Feeding",
	"Proteinfütterung":         "Protein feeding",
	"Kohlenhydrate":            "Carbohydrates",
	"Wasser":                   "Water",
	"Reinigung":                "Cleaning",
	"Kontrolle":                "Inspection",
	"Öffnen: %s":               "Open: %s",
	"Einstellen: Mehr → Benachrichtigungen": "Settings: More → Notifications",
	"Ameisen: %s": "Ants: %s",
	// digest
	"1 Kolonie braucht heute Aufmerksamkeit":    "1 colony needs attention today",
	"%d Kolonien brauchen heute Aufmerksamkeit": "%d colonies need attention today",
	" (%d überfällig)":                          " (%d overdue)",
	"Diese E-Mail kommt einmal täglich. Abbestellen: Mehr → Benachrichtigungen → Tages-Überblick.": "This e-mail comes once a day. Unsubscribe: More → Notifications → Daily overview.",
	// ntfy
	"Testnachricht – ntfy ist eingerichtet. 🐜":                          "Test message – ntfy is set up. 🐜",
	"ntfy nicht erreichbar: %v":                                         "ntfy not reachable: %v",
	"ntfy lehnt ab (%d) – Token oder Berechtigung für das Topic prüfen": "ntfy refuses (%d) – check the token or the permission for the topic",
	"ntfy antwortet %d: %s":                                             "ntfy answers %d: %s",
	// calendar subscription, Home Assistant (MQTT)
	"Ameisen":         "Ants",
	"Überfällig":      "Overdue",
	"Heute fällig":    "Due today",
	"In Winterruhe":   "Hibernating",
	"Kolonien":        "Colonies",
	"Nächste Pflege":  "Next care",
	"Nächste Aufgabe": "Next task",
	"Ameisenkolonie":  "Ant colony",
	"%s erledigt":     "%s done",
	// public colony page
	"Notiz":               "Note",
	"Messung":             "Measurement",
	"Koloniegröße":        "Colony size",
	"Brut":                "Brood",
	"Umzug":               "Move",
	"Königin":             "Queen",
	"Winterruhe begonnen": "Hibernation started",
	"Winterruhe beendet":  "Hibernation ended",
	"Aufgabe erledigt":    "Task done",
	"Aufgeschoben":        "Deferred",
	"über %d":             "over %d",
	// AI counting
	"Kein Guthaben bei Anthropic – unter console.anthropic.com → Billing aufladen": "No credit at Anthropic – top it up at console.anthropic.com → Billing",
	"Die KI lehnt den API-Schlüssel ab – in Server-Verwaltung → KI-Zählung prüfen": "The AI refuses the API key – check it in Server administration → AI counting",
	"Unbekanntes KI-Modell – in Server-Verwaltung → KI-Zählung prüfen":             "Unknown AI model – check it in Server administration → AI counting",
	"Die KI ist gerade ausgelastet – bitte später noch einmal":                     "The AI is busy right now – please try again later",
	"Die Fotos sind zu groß für die KI – weniger Fotos wählen":                     "The photos are too large for the AI – choose fewer photos",
	"Die KI meldet: %s": "The AI reports: %s",
	"Die KI antwortet mit HTTP %d – bitte später noch einmal":                              "The AI answers HTTP %d – please try again later",
	"Die KI hat zu lange gebraucht – weniger Fotos wählen":                                 "The AI took too long – choose fewer photos",
	"Zählen mit KI ist nicht eingerichtet (Administrator: Server-Verwaltung → KI-Zählung)": "Counting with AI is not set up (administrator: Server administration → AI counting)",
	"Die KI hat das Zählen dieser Fotos abgelehnt":                                         "The AI declined to count these photos",
	"Die Antwort der KI wurde abgeschnitten – weniger Fotos wählen":                        "The AI's answer was cut off – choose fewer photos",
	"Unlesbare Antwort der KI – bitte noch einmal":                                         "Unreadable answer from the AI – please try again",
	"Die KI hat nicht jedes Foto gezählt – bitte noch einmal":                              "The AI did not count every photo – please try again",
	"Kein Guthaben beim KI-Anbieter – dort aufladen":                                       "No credit at the AI provider – top it up there",
	"Die KI ist nicht erreichbar":                                                          "The AI is not reachable",
	// off-site backup warning
	"Backup außer Haus fehlt":                              "Off-site backup missing",
	"Seit %d Stunden hat kein Backup außer Haus geklappt.": "No off-site backup has worked for %d hours.",
	"Letzter Fehler: %s":                                   "Last error: %s",
	"Winterruhe an/aus":                                    "Hibernation on/off",
	// snooze
	"Auf morgen verschoben":              "Postponed to tomorrow",
	"Nichts mehr fällig":                 "Nothing due any more",
	"Winterruhe um einen Tag verschoben": "Hibernation moved by one day",
	// e-mail server, updates
	"Ant Colony Manager: Test-E-Mail":    "Ant Colony Manager: test e-mail",
	"Der E-Mail-Versand funktioniert. 🐜": "E-mail sending works. 🐜",
	"E-Mail-Versand fehlgeschlagen: %v":  "Sending e-mail failed: %v",
	"Update-Prüfung nicht möglich":       "Update check not possible",
	// password reset
	"Passwort zurücksetzen": "Reset password",
	"Hallo %s,\n\nüber diesen Link kannst du dein Passwort für Ant Colony Manager zurücksetzen (30 Minuten gültig):\n\n%s\n\nWenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.\n": "Hello %s,\n\nuse this link to reset your Ant Colony Manager password (valid for 30 minutes):\n\n%s\n\nIf you did not request this, you can ignore this e-mail.\n",
}

// tl translates de into lang and formats it with args.
func tl(lang, de string, args ...any) string {
	s := de
	if lang == "en" {
		if t, ok := enTexts[de]; ok {
			s = t
		}
	}
	if len(args) > 0 {
		s = fmt.Sprintf(s, args...)
	}
	return s
}

// resolveLang: the chosen language, otherwise what the user's app showed last.
func resolveLang(setting, hint *string) string {
	if setting != nil && languages[*setting] {
		return *setting
	}
	if hint != nil && languages[*hint] {
		return *hint
	}
	return "de"
}

// userLang is the language for messages to user.
func (s *Service) userLang(ctx context.Context, user uuid.UUID) string {
	var setting, hint *string
	_ = s.Pool.QueryRow(ctx, `SELECT us.locale, u.lang_hint FROM users u LEFT JOIN user_settings us ON us.id = u.id
		WHERE u.id = $1`, user).Scan(&setting, &hint)
	return resolveLang(setting, hint)
}

// langHints avoids a database write per request.
var langHints sync.Map // user id → language

// NoteLanguage remembers the language the user's app shows (Accept-Language:
// "en", "de-AT,de;q=0.9" …); used when the setting is „device language“.
func (s *Service) NoteLanguage(ctx context.Context, user uuid.UUID, acceptLanguage string) {
	lang := strings.ToLower(strings.TrimSpace(strings.SplitN(strings.SplitN(acceptLanguage, ",", 2)[0], "-", 2)[0]))
	if !languages[lang] {
		return
	}
	if prev, ok := langHints.Load(user); ok && prev == lang {
		return
	}
	if _, err := s.Pool.Exec(ctx, `UPDATE users SET lang_hint = $2 WHERE id = $1 AND lang_hint IS DISTINCT FROM $2`, user, lang); err == nil {
		langHints.Store(user, lang)
	}
}
