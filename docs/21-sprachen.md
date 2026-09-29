# Sprachen

Die App gibt es auf **Deutsch** und **Englisch**. Umschalten unter
**Mehr → Darstellung → Sprache**: *Gerätesprache* (Standard), Deutsch oder
English. Die Wahl gilt auf allen Geräten des Kontos.

E-Mails und ntfy-Nachrichten kommen in derselben Sprache: bei einer festen
Wahl in dieser, bei *Gerätesprache* in der Sprache, die die App zuletzt
angezeigt hat.

Noch nur auf Deutsch: die Inhalte der mitgelieferten Steckbriefe und des
Futter-Ratgebers im Artenkatalog (die Beschriftungen sind übersetzt).

## Technik

- Deutsch ist der Ausgangstext: `Text(tr('Speichern'))`, Platzhalter `{0}`, `{1}`:
  `tr('seit {0} Tagen überfällig', [tage])`. Siehe `app/lib/app/i18n.dart`.
- Übersetzungen: `app/tool/l10n/<sprache>.json` (deutscher Text → Übersetzung),
  daraus erzeugt `app/tool/i18n_gen.py <sprache>` die Datei `app/lib/l10n/<sprache>.dart`.
- `app/test/i18n_test.dart` schlägt fehl, wenn ein `tr()`-Text keine Übersetzung
  hat, Platzhalter nicht passen oder irgendwo deutscher Text ohne `tr()` steht.
- Server (E-Mail, ntfy, Sensor-Einträge): `server/internal/service/i18n.go`,
  geprüft von `TestServerTranslations`.

## Neue Sprache hinzufügen

1. `app/tool/l10n/en.json` nach `app/tool/l10n/<code>.json` kopieren (z. B. `fr`),
   die Werte übersetzen.
2. `cd app && python3 tool/i18n_gen.py fr` → `lib/l10n/fr.dart`.
3. In `app/lib/app/i18n.dart` unter `languages` eintragen:
   `'fr': ('Français', fr.table)` (Import `../l10n/fr.dart` as fr).
4. Server: in `server/internal/service/i18n.go` `languages` und eine
   Tabelle wie `enTexts` ergänzen; Migration `0008_language.sql` erlaubt
   bei `lang_hint` bisher nur `de`/`en` – neue Migration mit erweitertem CHECK.
