package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/anthropics/anthropic-sdk-go/shared/constant"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Counting ants with AI: the photos of a colony go to Claude (Anthropic API,
// key set up by the administrator), which counts the ants on each photo with
// a range. The app adds the photos up – e.g. front and back of a nest – and
// the user decides whether to take the result as colony size. Only the
// chosen photos (the 2048-px display version) leave the server.

const (
	aiKey          = "ai"
	aiDefaultModel = "claude-opus-5-5"
	aiMaxPhotos    = 6
)

type storedAI struct {
	Enabled   bool   `json:"enabled"`
	APIKeyEnc string `json:"api_key_enc,omitempty"`
	Model     string `json:"model,omitempty"`
}

// AISettings is the admin API shape; the key is write-only.
type AISettings struct {
	Enabled   bool    `json:"enabled"`
	APIKey    *string `json:"api_key,omitempty"` // input: nil = keep, "" = remove
	APIKeySet bool    `json:"api_key_set"`
	Model     string  `json:"model"`
}

// AICountPhoto is the count on one photo.
type AICountPhoto struct {
	PhotoID uuid.UUID `json:"photo_id"`
	Count   int       `json:"count"` // best estimate
	Min     int       `json:"min"`
	Max     int       `json:"max"`
	Queens  int       `json:"queens"`
	Note    string    `json:"note,omitempty"`
}

// AICountResult: per photo and added up.
type AICountResult struct {
	Photos  []AICountPhoto `json:"photos"`
	Total   int            `json:"total"`
	Min     int            `json:"min"`
	Max     int            `json:"max"`
	Overlap bool           `json:"overlap"` // the photos seem to show the same ants
	Note    string         `json:"note,omitempty"`
	Model   string         `json:"model"`
}

func (s *Service) loadAI(ctx context.Context) (storedAI, error) {
	var st storedAI
	_, err := s.loadJSONSetting(ctx, aiKey, &st)
	if st.Model == "" {
		st.Model = aiDefaultModel
	}
	return st, err
}

func (s *Service) GetAISettings(ctx context.Context, actor Actor) (*AISettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st, err := s.loadAI(ctx)
	if err != nil {
		return nil, err
	}
	return &AISettings{Enabled: st.Enabled, APIKeySet: st.APIKeyEnc != "", Model: st.Model}, nil
}

func (s *Service) SetAISettings(ctx context.Context, actor Actor, in AISettings, meta ClientMeta) (*AISettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	old, err := s.loadAI(ctx)
	if err != nil {
		return nil, err
	}
	in.Model = strings.TrimSpace(in.Model)
	if in.Model == "" {
		in.Model = aiDefaultModel
	}
	if !strings.HasPrefix(in.Model, "claude-") || len(in.Model) > 80 || strings.ContainsAny(in.Model, " /\r\n") {
		return nil, Invalid("model", "enter a Claude model id, e.g. %s", aiDefaultModel)
	}
	st := storedAI{Enabled: in.Enabled, APIKeyEnc: old.APIKeyEnc, Model: in.Model}
	if in.APIKey != nil {
		k := strings.TrimSpace(*in.APIKey)
		st.APIKeyEnc = ""
		if k != "" {
			if strings.ContainsAny(k, " \r\n") || len(k) > 500 {
				return nil, Invalid("api_key", "invalid API key")
			}
			if st.APIKeyEnc, err = s.encryptSecret(k); err != nil {
				return nil, err
			}
		}
	}
	if st.Enabled && st.APIKeyEnc == "" {
		return nil, Invalid("api_key", "enter the API key (console.anthropic.com → API Keys)")
	}
	if err := s.saveJSONSetting(ctx, aiKey, st); err != nil {
		return nil, err
	}
	s.Audit(ctx, &actor.UserID, "ai_settings_changed", "", map[string]any{"enabled": st.Enabled, "model": st.Model}, meta.IP)
	return s.GetAISettings(ctx, actor)
}

// AIAvailable tells the app whether to offer counting.
func (s *Service) AIAvailable(ctx context.Context) bool {
	st, err := s.loadAI(ctx)
	return err == nil && st.Enabled && st.APIKeyEnc != ""
}

const aiCountSystem = `You count ants on photos of an ant colony kept by a hobbyist (formicarium, test tube, nest).

For every photo separately:
- count: your best count of all adult ants visible (workers, soldiers, queens, winged males and females) – not eggs, larvae or pupae;
- min and max: a range the true number lies in; tight when you could count every ant, wider when ants overlap, are blurred, hidden or too many to count one by one;
- queens: the number of queens you can make out (0 if none are recognisable);
- note: one short sentence in the user's language about what made counting hard, or empty.

The photos may show different parts of the colony (e.g. front and back of a nest, nest and arena). They are added up. Set overlap to true only if several photos clearly show the same area, so that adding them would count the same ants twice. note (overall) may say so, in the user's language.`

var aiCountSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"photos": map[string]any{
			"type": "array",
			"items": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"photo":  map[string]any{"type": "integer", "description": "number of the photo, starting at 1"},
					"count":  map[string]any{"type": "integer"},
					"min":    map[string]any{"type": "integer"},
					"max":    map[string]any{"type": "integer"},
					"queens": map[string]any{"type": "integer"},
					"note":   map[string]any{"type": "string"},
				},
				"required":             []string{"photo", "count", "min", "max", "queens", "note"},
				"additionalProperties": false,
			},
		},
		"overlap": map[string]any{"type": "boolean"},
		"note":    map[string]any{"type": "string"},
	},
	"required":             []string{"photos", "overlap", "note"},
	"additionalProperties": false,
}

// AICount counts the ants on 1–6 photos of a colony.
func (s *Service) AICount(ctx context.Context, actor Actor, colony uuid.UUID, photos []uuid.UUID, meta ClientMeta) (*AICountResult, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return nil, err
	}
	lang := s.userLang(ctx, actor.UserID)
	st, err := s.loadAI(ctx)
	if err != nil {
		return nil, err
	}
	if !st.Enabled || st.APIKeyEnc == "" {
		return nil, &Problem{Status: http.StatusConflict, Code: "ai.not_set_up", Title: tl(lang, "Zählen mit KI ist nicht eingerichtet (Administrator: Server-Verwaltung → KI-Zählung)")}
	}
	if len(photos) == 0 || len(photos) > aiMaxPhotos {
		return nil, Invalid("photo_ids", "choose 1–%d photos", aiMaxPhotos)
	}
	key, err := s.decryptSecret(st.APIKeyEnc)
	if err != nil {
		return nil, fmt.Errorf("stored AI key cannot be decrypted (INSTANCE_SECRET changed?): %w", err)
	}

	// the photos, in the chosen order
	content := []anthropic.BetaContentBlockParamUnion{}
	for i, id := range photos {
		var storageKey *string
		err := s.Pool.QueryRow(ctx, `SELECT storage_key FROM photos
			WHERE id = $1 AND colony_id = $2 AND deleted_at IS NULL AND upload_state = 'stored'`, id, colony).Scan(&storageKey)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && storageKey == nil) {
			return nil, Invalid("photo_ids", "photo %s not found or not uploaded yet", id)
		}
		if err != nil {
			return nil, err
		}
		f, _, err := s.Blobs.Open(*storageKey)
		if err != nil {
			return nil, err
		}
		b, err := io.ReadAll(io.LimitReader(f, 8<<20))
		f.Close()
		if err != nil {
			return nil, err
		}
		content = append(content,
			anthropic.NewBetaTextBlock(fmt.Sprintf("Photo %d:", i+1)),
			anthropic.NewBetaImageBlock(anthropic.BetaBase64ImageSourceParam{
				Data: base64.StdEncoding.EncodeToString(b), MediaType: anthropic.BetaBase64ImageSourceMediaTypeImageJPEG,
			}))
	}
	language := map[string]string{"de": "German", "en": "English"}[lang]
	content = append(content, anthropic.NewBetaTextBlock(fmt.Sprintf(
		"Count the ants on each of the %d photos. The user's language is %s.", len(photos), language)))

	opts := []option.RequestOption{option.WithAPIKey(key), option.WithMaxRetries(1)}
	if s.AIBaseURL != "" {
		opts = append(opts, option.WithBaseURL(s.AIBaseURL))
	}
	client := anthropic.NewClient(opts...)
	ctx, cancel := context.WithTimeout(ctx, 100*time.Second)
	defer cancel()
	params := anthropic.BetaMessageNewParams{
		Model:     anthropic.Model(st.Model),
		MaxTokens: 16000,
		System:    []anthropic.BetaTextBlockParam{{Text: aiCountSystem}},
		Messages:  []anthropic.BetaMessageParam{anthropic.NewBetaUserMessage(content...)},
		OutputConfig: anthropic.BetaOutputConfigParam{
			Format: anthropic.BetaJSONOutputFormatParam{Schema: aiCountSchema},
		},
		// a safety classifier decline is answered by a suitable fallback model
		Fallbacks: anthropic.BetaFallbacksParamUnion{OfDefault: constant.ValueOf[constant.Default]()},
		Betas:     []anthropic.AnthropicBeta{anthropic.AnthropicBetaServerSideFallback2026_07_01},
	}
	resp, err := client.Beta.Messages.New(ctx, params)
	if msg := aiErrorMessage(err); msg != "" && strings.Contains(strings.ToLower(msg), "fallback") {
		// the account or model does not offer fallbacks – count without
		s.Log.Info("ai count: retrying without fallbacks", "reason", msg)
		params.Fallbacks, params.Betas = anthropic.BetaFallbacksParamUnion{}, nil
		resp, err = client.Beta.Messages.New(ctx, params)
	}
	if err != nil {
		s.Log.Warn("ai count failed", "model", st.Model, "err", err)
		return nil, aiError(lang, err)
	}
	switch resp.StopReason {
	case anthropic.BetaStopReasonRefusal:
		return nil, &Problem{Status: http.StatusBadGateway, Code: "ai.refused", Title: tl(lang, "Die KI hat das Zählen dieser Fotos abgelehnt")}
	case anthropic.BetaStopReasonMaxTokens:
		return nil, &Problem{Status: http.StatusBadGateway, Code: "ai.failed", Title: tl(lang, "Die Antwort der KI wurde abgeschnitten – weniger Fotos wählen")}
	}
	var text strings.Builder
	for _, b := range resp.Content {
		if t, ok := b.AsAny().(anthropic.BetaTextBlock); ok {
			text.WriteString(t.Text)
		}
	}
	var out struct {
		Photos []struct {
			Photo, Count, Min, Max, Queens int
			Note                           string
		} `json:"photos"`
		Overlap bool   `json:"overlap"`
		Note    string `json:"note"`
	}
	if err := json.Unmarshal([]byte(text.String()), &out); err != nil {
		return nil, &Problem{Status: http.StatusBadGateway, Code: "ai.failed", Title: tl(lang, "Unlesbare Antwort der KI – bitte noch einmal")}
	}
	res := &AICountResult{Photos: []AICountPhoto{}, Overlap: out.Overlap, Note: strings.TrimSpace(out.Note), Model: string(resp.Model)}
	for _, p := range out.Photos {
		if p.Photo < 1 || p.Photo > len(photos) {
			continue
		}
		c := AICountPhoto{PhotoID: photos[p.Photo-1], Count: max(p.Count, 0), Min: max(p.Min, 0), Max: max(p.Max, 0),
			Queens: max(p.Queens, 0), Note: strings.TrimSpace(p.Note)}
		// keep the range consistent whatever the model sent
		c.Min, c.Max = min(c.Min, c.Count), max(c.Max, c.Count)
		res.Photos = append(res.Photos, c)
		res.Total += c.Count
		res.Min += c.Min
		res.Max += c.Max
	}
	if len(res.Photos) != len(photos) {
		return nil, &Problem{Status: http.StatusBadGateway, Code: "ai.failed", Title: tl(lang, "Die KI hat nicht jedes Foto gezählt – bitte noch einmal")}
	}
	s.Audit(ctx, &actor.UserID, "ai_count", colony.String(), map[string]any{"photos": len(photos), "total": res.Total}, meta.IP)
	return res, nil
}

// aiErrorMessage: the message Anthropic sent with an error ("" if none).
func aiErrorMessage(err error) string {
	var apiErr *anthropic.Error
	if !errors.As(err, &apiErr) {
		return ""
	}
	var body struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(apiErr.RawJSON()), &body) == nil {
		return strings.TrimSpace(body.Error.Message)
	}
	return ""
}

// aiError turns API errors into messages the user can act on – in the
// user's language, with Anthropic's own reason where it helps.
func aiError(lang string, err error) error {
	fail := func(code, de string, args ...any) error {
		return &Problem{Status: http.StatusBadGateway, Code: code, Title: tl(lang, de, args...)}
	}
	var apiErr *anthropic.Error
	if errors.As(err, &apiErr) {
		msg := aiErrorMessage(err)
		low := strings.ToLower(msg)
		switch {
		case strings.Contains(low, "credit balance"):
			return fail("ai.credit", "Kein Guthaben bei Anthropic – unter console.anthropic.com → Billing aufladen")
		case apiErr.StatusCode == http.StatusUnauthorized || apiErr.StatusCode == http.StatusForbidden:
			return fail("ai.key", "Die KI lehnt den API-Schlüssel ab – in Server-Verwaltung → KI-Zählung prüfen")
		case apiErr.StatusCode == http.StatusNotFound:
			return fail("ai.model", "Unbekanntes KI-Modell – in Server-Verwaltung → KI-Zählung prüfen")
		case apiErr.StatusCode == http.StatusTooManyRequests || apiErr.StatusCode == 529:
			return fail("ai.busy", "Die KI ist gerade ausgelastet – bitte später noch einmal")
		case apiErr.StatusCode == http.StatusRequestEntityTooLarge:
			return fail("ai.failed", "Die Fotos sind zu groß für die KI – weniger Fotos wählen")
		case msg != "":
			return fail("ai.failed", "Die KI meldet: %s", msg)
		}
		return fail("ai.failed", "Die KI antwortet mit HTTP %d – bitte später noch einmal", apiErr.StatusCode)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &Problem{Status: http.StatusGatewayTimeout, Code: "ai.timeout", Title: tl(lang, "Die KI hat zu lange gebraucht – weniger Fotos wählen")}
	}
	return fail("ai.failed", "Die KI ist nicht erreichbar")
}
