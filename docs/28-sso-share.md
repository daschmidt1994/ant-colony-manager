# Anmeldung mit SSO und öffentlicher Share-Link

## Anmeldung mit SSO (OpenID Connect)

Wer schon einen Identity-Provider betreibt – Authentik, Keycloak, Authelia, Pocket ID, Zitadel oder auch Google bzw.
Microsoft – kann ACM daran anbinden. Auf der Anmeldeseite (App und Web) erscheint dann zusätzlich ein Knopf
„Mit … anmelden“. Die Anmeldung mit Passwort bleibt daneben möglich.

### Einrichten

1. **Beim Anbieter** einen Client vom Typ *OpenID Connect* (Authorization Code) anlegen:
   - **Weiterleitungs-URL (Redirect URI):** `<PUBLIC_APP_URL>/api/v1/auth/oidc/callback`
     – genau so zeigt ACM sie unter *Einstellungen → Anmeldung mit SSO* an (mit Kopier-Knopf).
   - **Scopes:** `openid email profile`
   - Client-Typ *vertraulich* (mit Secret) oder *öffentlich* (ohne Secret) – ACM nutzt immer PKCE.
2. **In ACM** als Admin unter *Einstellungen → Server-Verwaltung → Anmeldung mit SSO*:
   - **Issuer-URL** – die Adresse, unter der `/.well-known/openid-configuration` liegt,
     z. B. `https://auth.example.com/application/o/acm/` (Authentik) oder
     `https://sso.example.com/realms/home` (Keycloak).
   - **Client-ID** und ggf. **Client-Secret** (wird verschlüsselt gespeichert und nie wieder angezeigt).
   - **Name auf dem Knopf**, z. B. „Authentik“.
   - **Verbindung testen** prüft, ob der Anbieter erreichbar ist und die Issuer-URL stimmt.

`PUBLIC_APP_URL` muss die Adresse sein, unter der der Browser ACM erreicht – sonst passt die Weiterleitung nicht.

### Welches Konto wird angemeldet?

1. Hat sich die Person schon einmal per SSO angemeldet, gilt diese Verknüpfung (auch wenn sich die E-Mail beim
   Anbieter später ändert).
2. Sonst wird ein bestehendes ACM-Konto mit derselben **bestätigten** E-Mail-Adresse verknüpft. Eine E-Mail, die der
   Anbieter nicht als bestätigt meldet (`email_verified`), wird nie verknüpft.
3. Sonst nur, wenn **Neue Konten automatisch anlegen** an ist: dann bekommt jede Person, die der Anbieter durchlässt,
   ein neues Konto. Aus (Standard): Konten legt der Admin wie bisher an oder lädt ein.

### In der Android-App

Die App öffnet die Anmeldung im Browser; danach springt der Anbieter über `at.antcolony.manager://acm/sso` zurück in
die App (bei der Test-App `at.antcolony.manager.dev://…`). Andere Apps nimmt der Server nicht an. Der Rücksprung
enthält nur einen Einmal-Code, der 2 Minuten gilt und gegen die Sitzung getauscht wird.

## Öffentlicher Share-Link pro Kolonie

Für Haltungsberichte in Foren oder zum Zeigen im Freundeskreis: eine **schreibgeschützte Seite ohne Anmeldung**.

- Kolonie öffnen → Menü **⋮ → Öffentlich teilen** → *Öffentlichen Link erstellen* (nur die Besitzerin/der Besitzer).
- **Link kopieren** – die Seite `<PUBLIC_APP_URL>/p/<token>` zeigt Art, Status, Gründung, Königinnen,
  Koloniegröße mit Wachstumskurve, Fotos und Chronik.
- **Forenbeitrag kopieren** – fertiger BBCode mit Steckbrief, Fotos und Link; passt für die üblichen Ameisenforen
  (phpBB, vBulletin, …). Einfach in den Beitrag einfügen.
- Schalter **Fotos**, **Chronik** und **Notizen** (Texte von Notizen, Kontrollen, Fotos; standardmäßig aus).
- **Link widerrufen** – die Seite und eingebundene Fotos sind sofort weg, auch in schon geschriebenen Beiträgen.
  Ein neuer Link bekommt eine neue Adresse.

**Nie auf der Seite:** Fundort, Verkäufer, Standort/Raum, NFC-/QR-Code, Name oder E-Mail der Besitzerin, andere
Kolonien. Die Seite wird nicht von Suchmaschinen indexiert (`noindex`), lädt nichts von fremden Servern und hat eine
strenge Content-Security-Policy. Bis zu 5 Links pro Kolonie (etwa einer pro Forum).

Damit Forenleser die Seite öffnen können, muss ACM aus dem Internet erreichbar sein (siehe README, „Im Internet mit
HTTPS“). Wer nur `/p/` freigeben möchte, kann im Reverse-Proxy alles andere auf das Heimnetz beschränken.
