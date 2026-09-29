# Artenkatalog: Sprachen, invasive Arten, Schwarmflug-Kalender

## Steckbriefe auf Englisch

Die Katalog-Steckbriefe haben eine englische Fassung (`species.translations.en`, Migration 0011). Die App zeigt sie, wenn Englisch eingestellt ist; fehlt ein Feld, erscheint der deutsche Text. Die Suche findet Arten unter dem wissenschaftlichen, dem deutschen und dem übersetzten Namen. „Als eigene Art kopieren“ übernimmt die Texte in der gerade angezeigten Sprache.

Weitere Sprachen: dieselben Feldnamen unter einem neuen Sprachkürzel ergänzen (`{"en": {…}, "fr": {…}}`) – siehe [21-sprachen.md](21-sprachen.md).

## Invasive Arten (EU)

Die Unionsliste invasiver gebietsfremder Arten ([Verordnung (EU) Nr. 1143/2014](https://eur-lex.europa.eu/eli/reg/2014/1143/oj)) enthält seit der [Durchführungsverordnung (EU) 2022/1203](https://eur-lex.europa.eu/eli/reg_impl/2022/1203/oj) (gilt seit 2. August 2022) vier Ameisenarten:

| Art | Name |
|---|---|
| *Solenopsis invicta* | Rote Feuerameise |
| *Solenopsis richteri* | Schwarze Feuerameise |
| *Solenopsis geminata* | Tropische Feuerameise |
| *Wasmannia auropunctata* | Kleine Feuerameise |

Halten, Züchten, Kaufen, Verkaufen, Transportieren und Freisetzen sind in der EU verboten (Art. 7). Die Arten stehen im Katalog (`eu_invasive = true`) mit rechtlichem Hinweis; die App zeigt eine rote Warnung im Steckbrief, in der Artenliste und bei einer Kolonie – auch wenn die Art nur als Text eingetragen ist (schon beim Tippen im Formular). Ändert sich die Unionsliste, kommt eine neue Migration.

## Schwarmflug-Kalender

**Artenkatalog → Kalender-Symbol.** Pro Monat die Arten, deren Hochzeitsflug laut Steckbrief in diesen Monat fällt, mit einer Monatsleiste. Die Monate werden aus dem Feld „Hochzeitsflug“ gelesen („Juni – August“, „Mai-Juli“, „Juli“, auch Englisch und mehrere Zeiträume); ungenaue Angaben wie „Herbst“ oder „Regenzeit“ erscheinen nicht – der Kalender zeigt nur, was der Steckbrief als Monate angibt. Eigene Arten erscheinen, sobald ihr Hochzeitsflug so eingetragen ist.

**Glocke** (im Kalender oder im Steckbrief): In der ersten Woche jeder Schwarmflugzeit kommt eine App-Benachrichtigung („Schwarmflugzeit: Lasius niger“), einmal pro Jahr. Die Auswahl ist eine synchronisierte Einstellung (`user_settings.flight_watch`).
