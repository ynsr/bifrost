// Package clineoauth implements the Cline OAuth provider: Cline account
// tokens (from browser sign-in) with background access-token refresh.
// The cline-pass provider keeps serving static API keys untouched.
package clineoauth

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/maximhq/bifrost/core/providers/openai"
	providerUtils "github.com/maximhq/bifrost/core/providers/utils"
	schemas "github.com/maximhq/bifrost/core/schemas"
	"github.com/valyala/fasthttp"
)

// recommendedModelsPathSuffix is the upstream path (under the same base path
// as /v1) that lists the ClinePass recommended models.
const recommendedModelsPathSuffix = "/ai/cline/recommended-models"

// modelsCacheTTL bounds how often the recommended-models document is
// re-fetched; within the TTL the cached copy is served as-is.
const modelsCacheTTL = 5 * time.Minute

// fetchTimeout bounds a single upstream fetch of the document.
const fetchTimeout = 5 * time.Second

// refreshPathSuffix is the upstream token refresh path (under the same base
// path as /v1). Mirrors refreshClineToken in 9router's
// open-sse/services/tokenRefresh/providers.js.
const refreshPathSuffix = "/v1/auth/refresh"

// refreshTimeout bounds a single upstream token refresh call.
const refreshTimeout = 10 * time.Second

// refreshMargin refreshes the access token this long before expiry so an
// in-flight request never races the upstream TTL.
const refreshMargin = 5 * time.Minute

// maxRefreshBodyBytes caps the refresh response; it is a small JSON token
// document, never a stream.
const maxRefreshBodyBytes = 64 * 1024

// recModel is one entry of the recommended-models document.
type recModel struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Tags        []string `json:"tags"`
}

// recommendedResp is the shape of the Cline recommended-models document.
type recommendedResp struct {
	Recommended []recModel `json:"recommended"`
	Free        []recModel `json:"free"`
	ClinePass   []recModel `json:"clinePass"`
	ClineCloud  []recModel `json:"clineCloud"`
}

// modelsCache holds a cached model list with its fetch timestamp.
type modelsCache struct {
	mu      sync.Mutex
	models  []schemas.Model
	fetched time.Time
}

// ClineOAuthProvider implements the Provider interface for Cline API.
type ClineOAuthProvider struct {
	logger              schemas.Logger
	client              *fasthttp.Client
	streamingClient     *fasthttp.Client
	networkConfig       schemas.NetworkConfig
	sendBackRawRequest  bool
	sendBackRawResponse bool
	isKeyLess           bool

	modelsCache modelsCache // TTL-cached model list
	tokenMu     sync.Mutex
	tokenCache  map[string]*oauthTokenSlot // key ID -> live OAuth token
}

// oauthTokenSlot holds the live access token for one key.
type oauthTokenSlot struct {
	accessToken  string
	refreshToken string
	expiresAt    time.Time
}

// It initializes the HTTP client with the provided configuration.
func NewClineOAuthProvider(config *schemas.ProviderConfig, logger schemas.Logger) (*ClineOAuthProvider, error) {
	config.CheckAndSetDefaults()

	requestTimeout := time.Second * time.Duration(config.NetworkConfig.DefaultRequestTimeoutInSeconds)
	client := &fasthttp.Client{
		ReadTimeout:         requestTimeout,
		WriteTimeout:        requestTimeout,
		MaxConnsPerHost:     config.NetworkConfig.MaxConnsPerHost,
		MaxIdleConnDuration: time.Second * time.Duration(config.NetworkConfig.KeepAliveTimeoutInSeconds),
		MaxConnWaitTimeout:  requestTimeout,
		MaxConnDuration:     time.Second * time.Duration(schemas.DefaultMaxConnDurationInSeconds),
		ConnPoolStrategy:    fasthttp.FIFO,
	}

	// Configure proxy and retry policy
	client = providerUtils.ConfigureProxy(client, config.ProxyConfig, logger)
	client = providerUtils.ConfigureDialer(client, config.NetworkConfig.AllowPrivateNetwork)
	client = providerUtils.ConfigureTLS(client, config.NetworkConfig, logger)
	streamingClient := providerUtils.BuildStreamingClient(client)

	// Set default BaseURL if not provided
	if config.NetworkConfig.BaseURL == "" {
		config.NetworkConfig.BaseURL = "https://api.cline.bot/api"
	}
	config.NetworkConfig.BaseURL = strings.TrimRight(config.NetworkConfig.BaseURL, "/")

	// Determine if this is key-less (free) mode.
	// The provider is key-less when configured as a CustomProviderConfig with IsKeyLess=true,
	// or when no keys are provided in the standard provider config.
	isKeyLess := false
	if config.CustomProviderConfig != nil && config.CustomProviderConfig.IsKeyLess {
		isKeyLess = true
	}

	return &ClineOAuthProvider{
		logger:              logger,
		client:              client,
		streamingClient:     streamingClient,
		networkConfig:       config.NetworkConfig,
		sendBackRawRequest:  config.SendBackRawRequest,
		sendBackRawResponse: config.SendBackRawResponse,
		isKeyLess:           isKeyLess,
		tokenCache:          map[string]*oauthTokenSlot{},
	}, nil
}

func (provider *ClineOAuthProvider) GetProviderKey() schemas.ModelProvider {
	return schemas.ClineOAuth
}

// refreshRequest is the upstream token refresh body.
type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
	GrantType    string `json:"grantType"`
	ClientType   string `json:"clientType"`
}

// refreshResponseTokens is the token document inside the refresh response
// envelope (present either at the top level or under "data").
type refreshResponseTokens struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresAt    string `json:"expiresAt"`
	ExpiresIn    int64  `json:"expiresIn"`
}

// clineAccessToken applies the WorkOS prefix rule to a Cline account token:
// WorkOS JWTs (base64url eyJ header) are sent as `workos:<jwt>`; anything
// else goes verbatim. Mirrors getClineAccessToken in 9router's
// open-sse/shared/clineAuth.js.
func clineAccessToken(token string) string {
	trimmed := strings.TrimSpace(token)
	if trimmed == "" {
		return ""
	}
	if strings.HasPrefix(strings.ToLower(trimmed), "workos:") {
		return trimmed
	}
	if len(trimmed) > 4 && strings.HasPrefix(trimmed, "eyJ") &&
		strings.ContainsAny(trimmed[3:4], "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_") {
		return "workos:" + trimmed
	}
	return trimmed
}

// slotFor returns the live token slot for a key, seeding it from the key config.
func (provider *ClineOAuthProvider) slotFor(key schemas.Key) *oauthTokenSlot {
	id := key.ID
	if id == "" {
		id = key.Name
	}
	provider.tokenMu.Lock()
	defer provider.tokenMu.Unlock()
	if slot, ok := provider.tokenCache[id]; ok {
		return slot
	}
	slot := &oauthTokenSlot{}
	if cfg := key.ClineOAuthKeyConfig; cfg != nil {
		slot.accessToken = strings.TrimSpace(cfg.AccessToken.GetValue())
		slot.refreshToken = strings.TrimSpace(cfg.RefreshToken.GetValue())
	}
	provider.tokenCache[id] = slot
	return slot
}

// authHeader resolves the Bearer header for a key, refreshing the access
// token first when it is missing or near expiry.
func (provider *ClineOAuthProvider) authHeader(key schemas.Key) map[string]string {
	headers := map[string]string{}
	slot := provider.slotFor(key)
	provider.tokenMu.Lock()
	defer provider.tokenMu.Unlock()
	if slot.accessToken == "" || time.Until(slot.expiresAt) < refreshMargin {
		if refreshed, err := provider.refreshLocked(slot); err != nil {
			provider.logger.Warn("cline-oauth token refresh failed: %v", err)
		} else if refreshed != "" {
			slot.accessToken = refreshed
		}
	}
	if token := clineAccessToken(slot.accessToken); token != "" {
		headers["Authorization"] = "Bearer " + token
	}
	return headers
}

// refreshLocked exchanges the slot's refresh token for a new access token.
// Callers must hold tokenMu. On success it updates the slot in place and
// returns the new access token.
func (provider *ClineOAuthProvider) refreshLocked(slot *oauthTokenSlot) (string, error) {
	if slot.refreshToken == "" {
		return slot.accessToken, nil
	}
	body, err := json.Marshal(refreshRequest{
		RefreshToken: slot.refreshToken,
		GrantType:    "refresh_token",
		ClientType:   "extension",
	})
	if err != nil {
		return "", err
	}
	url := strings.TrimRight(provider.networkConfig.BaseURL, "/") + refreshPathSuffix
	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI(url)
	req.Header.SetMethod("POST")
	req.Header.SetContentType("application/json")
	req.Header.Set("Accept", "application/json")
	req.SetBody(body)
	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)
	if err := provider.client.DoTimeout(req, resp, refreshTimeout); err != nil {
		return "", err
	}
	if resp.StatusCode() != fasthttp.StatusOK {
		return "", fmt.Errorf("cline-oauth token refresh: upstream status %d", resp.StatusCode())
	}
	respBody := resp.Body()
	if len(respBody) > maxRefreshBodyBytes {
		respBody = respBody[:maxRefreshBodyBytes]
	}
	var envelope struct {
		Data refreshResponseTokens `json:"data"`
		refreshResponseTokens
	}
	if err := json.Unmarshal(respBody, &envelope); err != nil {
		return "", err
	}
	tokens := envelope.Data
	if tokens.AccessToken == "" {
		tokens = envelope.refreshResponseTokens
	}
	if tokens.AccessToken == "" {
		return "", fmt.Errorf("cline-oauth token refresh: no access token in response")
	}
	slot.accessToken = tokens.AccessToken
	if tokens.RefreshToken != "" {
		slot.refreshToken = tokens.RefreshToken
	}
	slot.expiresAt = parseRefreshExpiry(tokens)
	return slot.accessToken, nil
}

// parseRefreshExpiry derives the access-token expiry from the refresh
// response. expiresAt (RFC3339) wins; otherwise expiresIn seconds from now;
// otherwise a conservative 1-hour TTL.
func parseRefreshExpiry(tokens refreshResponseTokens) time.Time {
	if tokens.ExpiresAt != "" {
		if t, err := time.Parse(time.RFC3339, tokens.ExpiresAt); err == nil {
			return t
		}
	}
	if tokens.ExpiresIn > 0 {
		return time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second)
	}
	return time.Now().Add(time.Hour)
}

// recommendedURL builds the recommended-models document URL by appending
// the path directly to the base URL (which already includes any API prefix).
func (provider *ClineOAuthProvider) recommendedURL() string {
	return strings.TrimRight(provider.networkConfig.BaseURL, "/") + "/v1/ai/cline/recommended-models"
}

// fetchRecommendedModels fetches the recommended-models document from
// Cline API, injecting the first available API key as a bearer token.
// Uses the provider's pre-configured fasthttp client (which respects
// proxy_config, TLS settings, and SOCKS5 forwarding).
func (provider *ClineOAuthProvider) fetchRecommendedModels(keys []schemas.Key) ([]byte, error) {
	docURL := provider.recommendedURL()

	req := fasthttp.AcquireRequest()
	defer fasthttp.ReleaseRequest(req)
	req.SetRequestURI(docURL)
	req.Header.SetMethod("GET")

	// Inject Authorization header from the first key with a configured OAuth token
	for _, key := range keys {
		if h := provider.authHeader(key); h["Authorization"] != "" {
			req.Header.Set("Authorization", h["Authorization"])
			break
		}
	}

	// Add extra headers from configuration
	for k, v := range provider.networkConfig.ExtraHeaders {
		req.Header.Set(k, v)
	}

	resp := fasthttp.AcquireResponse()
	defer fasthttp.ReleaseResponse(resp)

	if err := provider.client.DoTimeout(req, resp, fetchTimeout); err != nil {
		return nil, fmt.Errorf("recommended-models fetch: %w", err)
	}

	if resp.StatusCode() != fasthttp.StatusOK {
		return nil, fmt.Errorf("recommended-models: upstream status %d", resp.StatusCode())
	}

	body := resp.Body()
	if len(body) > 4<<20 {
		body = body[:4<<20]
	}
	out := make([]byte, len(body))
	copy(out, body)
	return out, nil
}

// mergeModels parses a recommended-models document and merges the free
// and clinePass sub-lists (in that order, deduplicated by id) into
// Bifrost Model entries, prepending the "cline-oauth/" prefix to each
// model ID. This ensures ParseModelString strips "cline-oauth/" and
// leaves the upstream modelType/model format (e.g.
// "deepseek/deepseek-v4-flash") that the Cline API expects.
func mergeModels(doc []byte) []schemas.Model {
	var parsed recommendedResp
	if err := json.Unmarshal(doc, &parsed); err != nil {
		return nil
	}
	seen := map[string]bool{}
	var out []schemas.Model
	appendList := func(list []recModel) {
		for _, m := range list {
			if m.ID == "" || seen[m.ID] {
				continue
			}
			seen[m.ID] = true
			prefixedID := "cline-oauth/" + m.ID
			ownedBy := "cline-oauth"
			entry := schemas.Model{
				ID:      prefixedID,
				Name:    &m.Name,
				OwnedBy: &ownedBy,
			}
			if m.Description != "" {
				entry.Description = &m.Description
			}
			out = append(out, entry)
		}
	}
	appendList(parsed.Free)
	appendList(parsed.ClinePass)
	return out
}

// loadModelsFromCache returns the cached model list if it is fresh
// (within modelsCacheTTL). Returns nil when the cache is empty or stale.
func (provider *ClineOAuthProvider) loadModelsFromCache() []schemas.Model {
	provider.modelsCache.mu.Lock()
	defer provider.modelsCache.mu.Unlock()
	if provider.modelsCache.models != nil && time.Since(provider.modelsCache.fetched) < modelsCacheTTL {
		return provider.modelsCache.models
	}
	return nil
}

// storeModelsInCache replaces the cached model list and records the fetch timestamp.
func (provider *ClineOAuthProvider) storeModelsInCache(models []schemas.Model) {
	provider.modelsCache.mu.Lock()
	provider.modelsCache.models = models
	provider.modelsCache.fetched = time.Now()
	provider.modelsCache.mu.Unlock()
}

// loadStaleModels returns the cached model list regardless of age,
// for use as a fallback when the upstream fetch fails.
func (provider *ClineOAuthProvider) loadStaleModels() []schemas.Model {
	provider.modelsCache.mu.Lock()
	defer provider.modelsCache.mu.Unlock()
	return provider.modelsCache.models
}

// ListModels performs a list models request against Cline recommended-models
// API instead of the standard OpenAI /v1/models endpoint. The response
// merges the free and clinePass sub-lists (free first, deduplicated by id).
// Results are cached with a 5-minute TTL; stale cache is served when the
// upstream is unreachable.
func (provider *ClineOAuthProvider) ListModels(ctx *schemas.BifrostContext, keys []schemas.Key, request *schemas.BifrostListModelsRequest) (*schemas.BifrostListModelsResponse, *schemas.BifrostError) {
	listFunc := func() (*schemas.BifrostListModelsResponse, *schemas.BifrostError) {
		// Fast path: return fresh cached models
		if models := provider.loadModelsFromCache(); models != nil {
			return &schemas.BifrostListModelsResponse{Data: models}, nil
		}

		// Fetch the recommended-models document from Cline API
		doc, err := provider.fetchRecommendedModels(keys)
		if err != nil {
			// If fetch fails but stale cache exists, serve it
			if stale := provider.loadStaleModels(); stale != nil {
				provider.logger.Warn("recommended-models fetch failed; serving stale cache")
				return &schemas.BifrostListModelsResponse{Data: stale}, nil
			}
			return nil, providerUtils.NewBifrostOperationError(
				"failed to fetch recommended models: "+err.Error(), nil)
		}

		// Parse and merge free + clinePass lists
		models := mergeModels(doc)
		if models == nil {
			if stale := provider.loadStaleModels(); stale != nil {
				provider.logger.Warn("recommended-models document unusable; serving stale cache")
				return &schemas.BifrostListModelsResponse{Data: stale}, nil
			}
			return nil, providerUtils.NewBifrostOperationError(
				"failed to parse recommended-models document", nil)
		}

		// Update the cache and return
		provider.storeModelsInCache(models)
		return &schemas.BifrostListModelsResponse{Data: models}, nil
	}

	if provider.isKeyLess {
		return providerUtils.HandleKeylessListModelsRequest(provider.GetProviderKey(), listFunc)
	}
	return listFunc()
}

// ModelRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ModelRetrieve(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostModelRetrieveRequest) (*schemas.BifrostModelRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError("model retrieve", provider.GetProviderKey())
}

// TextCompletion is not supported by the Cline provider.
func (provider *ClineOAuthProvider) TextCompletion(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostTextCompletionRequest) (*schemas.BifrostTextCompletionResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError("text completion", provider.GetProviderKey())
}

// TextCompletionStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) TextCompletionStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostTextCompletionRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.TextCompletionStreamRequest, provider.GetProviderKey())
}

// resolveModelID looks up the full recommended-models document ID (e.g.
// "deepseek/deepseek-v4-flash") for a bare model name (e.g.
// "deepseek-v4-flash"). This handles backward compat with model slugs
// that were stored without the "modelType/" prefix before the cache was
// updated. Returns the bare name unchanged when no match is found, so
// requests are never silently dropped.
func (provider *ClineOAuthProvider) resolveModelID(bareModel string) string {
	models := provider.loadStaleModels()
	if models == nil {
		return bareModel
	}
	prefix := "cline-oauth/"
	for _, m := range models {
		if !strings.HasPrefix(m.ID, prefix) {
			continue
		}
		upstreamID := m.ID[len(prefix):] // e.g. "deepseek/deepseek-v4-flash"
		if i := strings.LastIndex(upstreamID, "/"); i >= 0 && upstreamID[i+1:] == bareModel {
			return upstreamID
		}
	}
	return bareModel
}

// ChatCompletion performs a chat completion request to Cline's API.
func (provider *ClineOAuthProvider) ChatCompletion(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostChatRequest) (*schemas.BifrostChatResponse, *schemas.BifrostError) {
	// Resolve bare model name to full model ID (e.g. "deepseek-v4-flash" → "deepseek/deepseek-v4-flash")
	// so the upstream Cline API receives the modelType/model format it expects.
	request.Model = provider.resolveModelID(request.Model)
	return openai.HandleOpenAIChatCompletionRequest(
		ctx,
		provider.client,
		provider.networkConfig.BaseURL+providerUtils.GetPathFromContext(ctx, "/v1/chat/completions"),
		request,
		provider.authHeader(key),
		provider.networkConfig.ExtraHeaders,
		providerUtils.ShouldSendBackRawRequest(ctx, provider.sendBackRawRequest),
		providerUtils.ShouldSendBackRawResponse(ctx, provider.sendBackRawResponse),
		provider.GetProviderKey(),
		nil,
		nil,
		nil,
		provider.logger,
	)
}

// ChatCompletionStream performs a streaming chat completion request to the Cline API.
func (provider *ClineOAuthProvider) ChatCompletionStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostChatRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	request.Model = provider.resolveModelID(request.Model)
	return openai.HandleOpenAIChatCompletionStreaming(
		ctx,
		provider.streamingClient,
		provider.networkConfig.BaseURL+"/v1/chat/completions",
		request,
		provider.authHeader(key),
		provider.networkConfig.ExtraHeaders,
		provider.networkConfig.StreamIdleTimeoutInSeconds,
		providerUtils.ShouldSendBackRawRequest(ctx, provider.sendBackRawRequest),
		providerUtils.ShouldSendBackRawResponse(ctx, provider.sendBackRawResponse),
		provider.GetProviderKey(),
		postHookRunner,
		nil,
		nil,
		nil,
		nil,
		nil,
		nil,
		provider.logger,
		postHookSpanFinalizer,
	)
}

// Responses performs a responses request to the Cline API.
func (provider *ClineOAuthProvider) Responses(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostResponsesRequest) (*schemas.BifrostResponsesResponse, *schemas.BifrostError) {
	chatResponse, err := provider.ChatCompletion(ctx, key, request.ToChatRequest())
	if err != nil {
		return nil, err
	}

	response := chatResponse.ToBifrostResponsesResponse()

	return response, nil
}

// ResponsesStream performs a streaming responses request to the Cline API.
func (provider *ClineOAuthProvider) ResponsesStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostResponsesRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	ctx.SetValue(schemas.BifrostContextKeyIsResponsesToChatCompletionFallback, true)
	return provider.ChatCompletionStream(
		ctx,
		postHookRunner,
		postHookSpanFinalizer,
		key,
		request.ToChatRequest(),
	)
}

// Embedding is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Embedding(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostEmbeddingRequest) (*schemas.BifrostEmbeddingResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.EmbeddingRequest, provider.GetProviderKey())
}

// Rerank is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Rerank(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostRerankRequest) (*schemas.BifrostRerankResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.RerankRequest, provider.GetProviderKey())
}

// OCR is not supported by the Cline provider.
func (provider *ClineOAuthProvider) OCR(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostOCRRequest) (*schemas.BifrostOCRResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.OCRRequest, provider.GetProviderKey())
}

// Decision is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Decision(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostDecisionRequest) (*schemas.BifrostDecisionResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.DecisionRequest, provider.GetProviderKey())
}

// Speech is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Speech(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostSpeechRequest) (*schemas.BifrostSpeechResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.SpeechRequest, provider.GetProviderKey())
}

// SpeechStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) SpeechStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostSpeechRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.SpeechStreamRequest, provider.GetProviderKey())
}

// Transcription is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Transcription(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostTranscriptionRequest) (*schemas.BifrostTranscriptionResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.TranscriptionRequest, provider.GetProviderKey())
}

// TranscriptionStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) TranscriptionStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostTranscriptionRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.TranscriptionStreamRequest, provider.GetProviderKey())
}

// ImageGeneration is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ImageGeneration(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostImageGenerationRequest) (*schemas.BifrostImageGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ImageGenerationRequest, provider.GetProviderKey())
}

// ImageGenerationStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ImageGenerationStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostImageGenerationRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ImageGenerationStreamRequest, provider.GetProviderKey())
}

// ImageEdit is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ImageEdit(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostImageEditRequest) (*schemas.BifrostImageGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ImageEditRequest, provider.GetProviderKey())
}

// ImageEditStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ImageEditStream(ctx *schemas.BifrostContext, postHookRunner schemas.PostHookRunner, postHookSpanFinalizer func(context.Context), key schemas.Key, request *schemas.BifrostImageEditRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ImageEditStreamRequest, provider.GetProviderKey())
}

// ImageVariation is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ImageVariation(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostImageVariationRequest) (*schemas.BifrostImageGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ImageVariationRequest, provider.GetProviderKey())
}

// VideoGeneration is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoGeneration(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoGenerationRequest) (*schemas.BifrostVideoGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoGenerationRequest, provider.GetProviderKey())
}

// VideoEdit is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoEdit(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoEditRequest) (*schemas.BifrostVideoEditResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoEditRequest, provider.GetProviderKey())
}

// VideoRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoRetrieve(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoRetrieveRequest) (*schemas.BifrostVideoGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoRetrieveRequest, provider.GetProviderKey())
}

// VideoDownload is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoDownload(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoDownloadRequest) (*schemas.BifrostVideoDownloadResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoDownloadRequest, provider.GetProviderKey())
}

// VideoDelete is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoDelete(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoDeleteRequest) (*schemas.BifrostVideoDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoDeleteRequest, provider.GetProviderKey())
}

// VideoList is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoList(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoListRequest) (*schemas.BifrostVideoListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoListRequest, provider.GetProviderKey())
}

// VideoRemix is not supported by the Cline provider.
func (provider *ClineOAuthProvider) VideoRemix(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostVideoRemixRequest) (*schemas.BifrostVideoGenerationResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.VideoRemixRequest, provider.GetProviderKey())
}

// BatchCreate is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchCreate(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostBatchCreateRequest) (*schemas.BifrostBatchCreateResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchCreateRequest, provider.GetProviderKey())
}

// BatchList is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchList(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostBatchListRequest) (*schemas.BifrostBatchListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchListRequest, provider.GetProviderKey())
}

// BatchRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchRetrieve(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostBatchRetrieveRequest) (*schemas.BifrostBatchRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchRetrieveRequest, provider.GetProviderKey())
}

// BatchCancel is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchCancel(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostBatchCancelRequest) (*schemas.BifrostBatchCancelResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchCancelRequest, provider.GetProviderKey())
}

// BatchDelete is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchDelete(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostBatchDeleteRequest) (*schemas.BifrostBatchDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchDeleteRequest, provider.GetProviderKey())
}

// BatchResults is not supported by the Cline provider.
func (provider *ClineOAuthProvider) BatchResults(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostBatchResultsRequest) (*schemas.BifrostBatchResultsResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.BatchResultsRequest, provider.GetProviderKey())
}

// FileUpload is not supported by the Cline provider.
func (provider *ClineOAuthProvider) FileUpload(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostFileUploadRequest) (*schemas.BifrostFileUploadResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.FileUploadRequest, provider.GetProviderKey())
}

// FileList is not supported by the Cline provider.
func (provider *ClineOAuthProvider) FileList(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostFileListRequest) (*schemas.BifrostFileListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.FileListRequest, provider.GetProviderKey())
}

// FileRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) FileRetrieve(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostFileRetrieveRequest) (*schemas.BifrostFileRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.FileRetrieveRequest, provider.GetProviderKey())
}

// FileDelete is not supported by the Cline provider.
func (provider *ClineOAuthProvider) FileDelete(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostFileDeleteRequest) (*schemas.BifrostFileDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.FileDeleteRequest, provider.GetProviderKey())
}

// FileContent is not supported by the Cline provider.
func (provider *ClineOAuthProvider) FileContent(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostFileContentRequest) (*schemas.BifrostFileContentResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.FileContentRequest, provider.GetProviderKey())
}

// CountTokens is not supported by the Cline provider.
func (provider *ClineOAuthProvider) CountTokens(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostResponsesRequest) (*schemas.BifrostCountTokensResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CountTokensRequest, provider.GetProviderKey())
}

// Compaction is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Compaction(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostCompactionRequest) (*schemas.BifrostCompactionResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CompactionRequest, provider.GetProviderKey())
}

// ContainerCreate is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerCreate(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostContainerCreateRequest) (*schemas.BifrostContainerCreateResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerCreateRequest, provider.GetProviderKey())
}

// ContainerList is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerList(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerListRequest) (*schemas.BifrostContainerListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerListRequest, provider.GetProviderKey())
}

// ContainerRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerRetrieve(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerRetrieveRequest) (*schemas.BifrostContainerRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerRetrieveRequest, provider.GetProviderKey())
}

// ContainerDelete is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerDelete(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerDeleteRequest) (*schemas.BifrostContainerDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerDeleteRequest, provider.GetProviderKey())
}

// ContainerFileCreate is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerFileCreate(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostContainerFileCreateRequest) (*schemas.BifrostContainerFileCreateResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerFileCreateRequest, provider.GetProviderKey())
}

// ContainerFileList is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerFileList(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerFileListRequest) (*schemas.BifrostContainerFileListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerFileListRequest, provider.GetProviderKey())
}

// ContainerFileRetrieve is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerFileRetrieve(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerFileRetrieveRequest) (*schemas.BifrostContainerFileRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerFileRetrieveRequest, provider.GetProviderKey())
}

// ContainerFileContent is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerFileContent(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerFileContentRequest) (*schemas.BifrostContainerFileContentResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerFileContentRequest, provider.GetProviderKey())
}

// ContainerFileDelete is not supported by the Cline provider.
func (provider *ClineOAuthProvider) ContainerFileDelete(_ *schemas.BifrostContext, _ []schemas.Key, _ *schemas.BifrostContainerFileDeleteRequest) (*schemas.BifrostContainerFileDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.ContainerFileDeleteRequest, provider.GetProviderKey())
}

// Passthrough is not supported by the Cline provider.
func (provider *ClineOAuthProvider) Passthrough(_ *schemas.BifrostContext, _ schemas.Key, _ *schemas.BifrostPassthroughRequest) (*schemas.BifrostPassthroughResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.PassthroughRequest, provider.GetProviderKey())
}

// PassthroughStream is not supported by the Cline provider.
func (provider *ClineOAuthProvider) PassthroughStream(_ *schemas.BifrostContext, _ schemas.PostHookRunner, _ func(context.Context), _ schemas.Key, _ *schemas.BifrostPassthroughRequest) (chan *schemas.BifrostStreamChunk, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.PassthroughStreamRequest, provider.GetProviderKey())
}

// CachedContentCreate is unsupported on ClineOAuthProvider. Only Gemini and Vertex AI
// implement the cached-content lifecycle (Google AI Studio + Vertex AI named
// caches). Other providers either lack named cache management entirely or
// handle caching implicitly via per-message cache_control markers.
func (provider *ClineOAuthProvider) CachedContentCreate(ctx *schemas.BifrostContext, key schemas.Key, request *schemas.BifrostCachedContentCreateRequest) (*schemas.BifrostCachedContentCreateResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CachedContentCreateRequest, provider.GetProviderKey())
}

// CachedContentList is unsupported on ClineOAuthProvider (see CachedContentCreate).
func (provider *ClineOAuthProvider) CachedContentList(ctx *schemas.BifrostContext, keys []schemas.Key, request *schemas.BifrostCachedContentListRequest) (*schemas.BifrostCachedContentListResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CachedContentListRequest, provider.GetProviderKey())
}

// CachedContentRetrieve is unsupported on ClineOAuthProvider (see CachedContentCreate).
func (provider *ClineOAuthProvider) CachedContentRetrieve(ctx *schemas.BifrostContext, keys []schemas.Key, request *schemas.BifrostCachedContentRetrieveRequest) (*schemas.BifrostCachedContentRetrieveResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CachedContentRetrieveRequest, provider.GetProviderKey())
}

// CachedContentUpdate is unsupported on ClineOAuthProvider (see CachedContentCreate).
func (provider *ClineOAuthProvider) CachedContentUpdate(ctx *schemas.BifrostContext, keys []schemas.Key, request *schemas.BifrostCachedContentUpdateRequest) (*schemas.BifrostCachedContentUpdateResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CachedContentUpdateRequest, provider.GetProviderKey())
}

// CachedContentDelete is unsupported on ClineOAuthProvider (see CachedContentCreate).
func (provider *ClineOAuthProvider) CachedContentDelete(ctx *schemas.BifrostContext, keys []schemas.Key, request *schemas.BifrostCachedContentDeleteRequest) (*schemas.BifrostCachedContentDeleteResponse, *schemas.BifrostError) {
	return nil, providerUtils.NewUnsupportedOperationError(schemas.CachedContentDeleteRequest, provider.GetProviderKey())
}
