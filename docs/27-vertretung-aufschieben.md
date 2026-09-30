# Pflegevertretung und Aufschieben mit Grund

## Pflegevertretung

Urlaub, Krankheit, Dienstreise: **Mehr → Pflegevertretung → „+ Vertretung“**

| Feld | |
|---|---|
| E-Mail der Vertretung | Die Person braucht ein Konto auf diesem Server (sonst zuerst einladen) |
| Zeitraum | von – bis (ganze Tage, nach Serverdatum) |
| Pflegeanweisungen | gelten für alle gewählten Kolonien, z. B. „Proteinfutter nur jeden zweiten Tag“ |
| Kolonien | nur eigene; je Kolonie optional eine eigene Anweisung |

- **Im Zeitraum** ist die Person **Pfleger** der gewählten Kolonien: sie sieht sie in ihrer App, bekommt die Erinnerungen und kann Pflege eintragen. Der Server schaltet das zum Beginn frei und am Ende wieder ab (Prüfung jede Minute). Eine schon bestehende Freigabe derselben Person bleibt unverändert.
- **Die Vertretung** sieht in jeder dieser Kolonien oben die Anweisungen, und unter Mehr → Pflegevertretung die ganze Übergabe.
- **Du** siehst in der Vertretung unter **„Erledigt“** alles, was sie in dieser Zeit eingetragen hat – auch nach dem Ende.
- **Ende ändern** (verlängern oder verkürzen) kann der Besitzer, **beenden** können beide. Eine noch nicht begonnene Vertretung wird beim Beenden gelöscht. Wird die Person von Hand aus einer Kolonie entfernt, bleibt sie für diese Kolonie draußen.

Schnittstelle: `GET/POST /api/v1/care-covers`, `GET/PATCH /api/v1/care-covers/{id}`, `POST /api/v1/care-covers/{id}/end`, `GET /api/v1/colonies/{id}/care-instructions`.

## Aufschieben mit Grund

Nicht jede fällige Pflege ist nötig – das Reagenzglas ist noch halb voll, das Futter vom letzten Mal liegt noch da. Statt die Aufgabe nur zu verschieben: **langes Tippen auf eine fällige Aufgabe → „Aufschieben mit Grund …“**

- Grund wählen – passend zur Aufgabe: *Noch ausreichend Wasser*, *Futter nicht angenommen*, *Noch Futter übrig*, *Noch sauber*, *Kolonie in Ruhe lassen*, *Keine Zeit*, *Anderer Grund*
- wie lange: 1, 2, 3 oder 7 Tage (je nach Intervall)
- optional eine Notiz

In der **Chronik** steht dann z. B. „Wasser aufgeschoben: Noch ausreichend Wasser (3 Tage) – Reagenzglas noch halb voll“; die Aufgabe ist erst danach wieder fällig. Funktioniert offline, „Rückgängig“ macht beides rückgängig. Der schnelle Weg ohne Grund bleibt „Auf morgen verschieben“.
