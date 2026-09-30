# Sensoren (Temperatur & Luftfeuchtigkeit)

Ein ESP32, ein anderer WLAN-Sensor oder ein Gateway (z. B. für Bluetooth-Sensoren) schickt Messwerte direkt an den eigenen Server. Die Werte erscheinen in der **Statistik der Kolonie** (Temperatur/Luftfeuchtigkeit, zusammen mit manuellen Messungen) und im **CSV-Export**.

## Einrichten

1. App/Web → **Mehr → Sensoren → „Sensor“**: Name, Art und Kolonie wählen.
2. Der **API-Schlüssel wird genau einmal angezeigt** (Adresse, Schlüssel und ein `curl`-Beispiel zum Kopieren). Verloren? → Sensor antippen → „Neuen Schlüssel erzeugen“ (der alte wird sofort ungültig).
3. Optional **Grenzwerte** (Temperatur min/max, Luftfeuchte min/max) eintragen.

## Werte aus Home Assistant

Hängt der Sensor schon an Home Assistant (Zigbee, Bluetooth, ESPHome …), braucht er keine eigene Verbindung: Art **„Home Assistant“** wählen und die Entitäten eintragen, z. B. `sensor.formicarium_temperature` und `sensor.formicarium_humidity` (Home Assistant → Einstellungen → Entitäten). Der Server liest sie alle 5 Minuten über die REST-API von Home Assistant; Grenzwerte, Alarme und Statistik funktionieren wie bei jedem anderen Sensor.

Einmalig richtet der Administrator die Verbindung ein: **Mehr → Server-Verwaltung → Home Assistant (MQTT) → Sensorwerte aus Home Assistant** – Adresse (z. B. `http://192.168.178.199:8123`) und ein **langlebiges Zugriffstoken** (Home Assistant: Profil unten links → Sicherheit → „Langlebige Zugriffstoken“). Gelesen werden nur Sensoren von Benutzern, die ihre Kolonien an Home Assistant senden.

## Schnittstelle

```http
POST /api/v1/sensors/{sensor-id}/measurements
Authorization: Bearer acm_sk_…
Content-Type: application/json

{"readings": [
  {"metric": "temperature", "value": 24.5},
  {"metric": "humidity", "value": 62, "measured_at": "2026-09-27T08:15:00Z"}
]}
```

| Feld | Bedeutung |
|---|---|
| `metric` | `temperature` (°C, −40…80) oder `humidity` (%, 0…100) |
| `value` | Messwert |
| `measured_at` | optional (ISO 8601); ohne Angabe gilt der Empfangszeitpunkt |

- Bis zu 500 Werte pro Anfrage – ein Sensor ohne WLAN kann puffern und später nachliefern.
- Doppelte Sendungen (gleicher Sensor, Messgröße und Zeitpunkt) werden ignoriert.
- Antwort `202 {"stored": 2, "received": 2}`; `401` bei falschem Schlüssel oder deaktiviertem Sensor; Ratenbegrenzung pro Sensor.
- Der Schlüssel gilt nur für diesen einen Sensor und kann sonst nichts lesen oder schreiben.

## Automatisierungen

- **Grenzwert überschritten:** Der neueste Wert einer Sendung liegt außerhalb → der Server trägt bei der Kolonie ein **„Problem“** ein („Sensor „Regal A“: Temperatur 31,5 °C – über dem Grenzwert 28,0 °C.“). Die Android-App meldet es als Benachrichtigung. Höchstens ein Alarm pro Sensor und Messgröße alle 6 Stunden; nachgelieferte Werte älter als 2 Stunden lösen keinen Alarm aus.
- **Sensor stumm:** Sendet ein aktiver Sensor länger als 6 Stunden nichts, meldet die App das („Stromversorgung oder WLAN prüfen“).

## Beispiel: ESP32 mit SHT31 (Arduino)

```cpp
#include <WiFi.h>
#include <HTTPClient.h>
#include <Adafruit_SHT31.h>

const char* WIFI_SSID = "…";
const char* WIFI_PASS = "…";
const char* URL = "http://192.168.1.10:8080/api/v1/sensors/<sensor-id>/measurements";
const char* KEY = "acm_sk_…";

Adafruit_SHT31 sht;

void setup() {
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) delay(500);
  sht.begin(0x44);
}

void loop() {
  float t = sht.readTemperature(), h = sht.readHumidity();
  if (!isnan(t) && !isnan(h)) {
    HTTPClient http;
    http.begin(URL);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("Authorization", String("Bearer ") + KEY);
    String body = "{\"readings\":[{\"metric\":\"temperature\",\"value\":" + String(t, 1) +
                  "},{\"metric\":\"humidity\",\"value\":" + String(h, 0) + "}]}";
    http.POST(body);
    http.end();
  }
  delay(5 * 60 * 1000); // alle 5 Minuten
}
```

Hinter HTTPS (Reverse Proxy) `WiFiClientSecure` verwenden; im Heimnetz reicht die interne Adresse des Servers.
