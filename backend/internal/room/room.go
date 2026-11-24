package room

import (
	"encoding/json"
	"log"
	"sync"
)

// Message — пакет сигнализации, пересылаемый между участниками встречи.
type Message struct {
	Type      string          `json:"type"`
	From      string          `json:"from"`
	To        string          `json:"to,omitempty"`
	Role      string          `json:"role,omitempty"`
	Name      string          `json:"name,omitempty"`
	Names     []string        `json:"names,omitempty"`
	Active    bool            `json:"active,omitempty"`
	Forced    bool            `json:"forced,omitempty"`
	Mic       bool            `json:"mic,omitempty"`
	Camera    bool            `json:"camera,omitempty"`
	Allow     bool            `json:"allow,omitempty"`
	StreamID  string          `json:"streamId,omitempty"`
	Aspect    float64         `json:"aspect,omitempty"` // w/h картинки трансляции
	Points    []float64       `json:"points,omitempty"` // нормализованные 0..1
	Color     string          `json:"color,omitempty"`
	Width     float64         `json:"width,omitempty"`
	Clear     bool            `json:"clear,omitempty"`
	SDP       json.RawMessage `json:"sdp,omitempty"`
	Candidate json.RawMessage `json:"candidate,omitempty"`
	Ice       json.RawMessage `json:"ice,omitempty"`
	Text      string          `json:"text,omitempty"`  // текст сообщения чата
	Emoji     string          `json:"emoji,omitempty"` // эмодзи реакции
	Image     string          `json:"image,omitempty"` // PNG-снимок доски (base64)
}

// Типы сообщений протокола.
const (
	TypeJoin        = "join"
	TypeJoined      = "joined"
	TypePeers       = "peers"
	TypePeerJoin    = "peer-joined"
	TypeOffer       = "offer"
	TypeAnswer      = "answer"
	TypeIce         = "ice"
	TypeLeave       = "leave"
	TypePeerLeave   = "peer-leave"
	TypeScreen      = "screen"
	TypeDevice      = "device"
	TypePolicy      = "share-policy"
	TypeShareDenied = "share-denied"
	TypeRenegotiate = "renegotiate"
	TypeDraw        = "draw"
	TypeChat        = "chat"
	TypeReaction    = "reaction"
	TypeBoardImage  = "board-image"
)

// Client — один подключённый к комнате участник.
type Client struct {
	id         string // uid пользователя
	room       string // meetingId
	name       string // отображаемое имя
	role       string // offerer | answerer
	isTeacher  bool   // учитель (организатор) встречи
	superseded bool   // заменено новым соединением того же uid (перезагрузка)
	send       chan []byte
	hub        *Hub
}

// Hub — набор комнат. Каждая комната — это «переговорная» со всеми участниками
// встречи; сервер управляет ролями, одиночной трансляцией экрана и политикой
// «кто может показывать экран», а остальное просто ретранслирует.
type Hub struct {
	mu            sync.Mutex
	rooms         map[string]map[*Client]bool
	offerer       map[string]string  // roomID → uid offerer'а (инициатора звонка)
	screenOwner   map[string]string  // roomID → uid текущего ведущего трансляции
	screenStream  map[string]string  // roomID → streamId текущей трансляции
	screenAspect  map[string]float64 // roomID → пропорции (w/h) трансляции
	allowStudents map[string]bool    // roomID → разрешено ли ученикам показывать экран (по умолчанию да)
}

func NewHub() *Hub {
	return &Hub{
		rooms:         make(map[string]map[*Client]bool),
		offerer:       make(map[string]string),
		screenOwner:   make(map[string]string),
		screenStream:  make(map[string]string),
		screenAspect:  make(map[string]float64),
		allowStudents: make(map[string]bool),
	}
}

// clientPresent проверяет, есть ли в комнате клиент с таким uid.
func (h *Hub) clientPresent(peers map[*Client]bool, id string) bool {
	for peer := range peers {
		if peer.id == id {
			return true
		}
	}
	return false
}

// AddClient добавляет клиента в комнату и назначает ему роль.
//
// Роль offerer (инициатор звонка) закреплена за комнатой по uid: участник,
// вошедший первым, становится offerer'ом и остаётся им (роль «переживает»
// перезагрузку). При перезагрузке offerer возвращается в комнату — другим
// снова приходит роль answerer. А если прежний offerer пропал — новый
// участник берёт эту роль на себя. Так всегда ровно один offerer, и никогда
// не бывает рассинхрона, когда offerer'ов ноль или двое.
func (h *Hub) AddClient(id, roomID, name string, isTeacher bool) *Client {
	h.mu.Lock()
	defer h.mu.Unlock()

	peers := h.rooms[roomID]
	if peers == nil {
		peers = make(map[*Client]bool)
		h.rooms[roomID] = peers
	}

	// Если от этого же пользователя уже есть живое соединение (перезагрузка
	// страницы или переподключение), старое объявляем заменённым: его
	// «прощание» не должно рассылать peer-leave и снимать трансляцию экрана
	// у только что пришедшего нового соединения. Заменённое соединение сразу
	// убираем из комнаты — иначе оно ещё до 90 секунд (pongDeadline)
	// числится среди участников, а собеседник остаётся с признаком живого
	// пира и не пересобирает медиа при новом входе с другого устройства.
	superseded := false
	for p := range peers {
		if p.id == id {
			p.superseded = true
			superseded = true
			delete(peers, p)
		}
	}

	role := "answerer"
	switch {
	case len(peers) == 0:
		// Комната пустая — этот участник и есть offerer.
		role = "offerer"
		h.offerer[roomID] = id
	case superseded && h.offerer[roomID] == id:
		// Переподключается текущий offerer: роль остаётся за ним, иначе
		// могли бы остаться два answerer'а и никто не начал бы звонок.
		role = "offerer"
	case h.offerer[roomID] == "" || !h.clientPresent(peers, h.offerer[roomID]):
		// Прежний offerer пропал (перезагрузил страницу, вышел) —
		// новый участник занимает его место.
		role = "offerer"
		h.offerer[roomID] = id
	}

	c := &Client{
		id:        id,
		room:      roomID,
		name:      name,
		role:      role,
		isTeacher: isTeacher,
		send:      make(chan []byte, 128),
		hub:       h,
	}
	peers[c] = true
	return c
}

func (h *Hub) RemoveClient(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.offerer[c.room] == c.id && !c.superseded {
		delete(h.offerer, c.room)
	}
	if peers := h.rooms[c.room]; peers != nil {
		delete(peers, c)
		if len(peers) == 0 {
			delete(h.rooms, c.room)
			delete(h.offerer, c.room)
			delete(h.screenOwner, c.room)
			delete(h.screenStream, c.room)
			delete(h.screenAspect, c.room)
			delete(h.allowStudents, c.room)
		}
	}
}

// PeerNames возвращает имена участников комнаты, кроме except.
func (h *Hub) PeerNames(roomID string, except *Client) []string {
	h.mu.Lock()
	defer h.mu.Unlock()

	names := make([]string, 0, len(h.rooms[roomID]))
	for peer := range h.rooms[roomID] {
		if peer == except {
			continue
		}
		names = append(names, peer.name)
	}
	return names
}

// FindClient возвращает клиента комнаты по uid (nil, если его нет).
func (h *Hub) FindClient(roomID, id string) *Client {
	h.mu.Lock()
	defer h.mu.Unlock()

	for peer := range h.rooms[roomID] {
		if peer.id == id {
			return peer
		}
	}
	return nil
}

// SendTo отправляет сообщение конкретному клиенту (без блокировки).
func (h *Hub) SendTo(c *Client, msg []byte) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	select {
	case c.send <- msg:
		return true
	default:
		log.Printf("room %s: клиент %s не успевает принимать, пропускаю", c.room, c.id)
		return false
	}
}

// ScreenOwner возвращает uid текущего ведущего трансляции.
func (h *Hub) ScreenOwner(roomID string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	uid, ok := h.screenOwner[roomID]
	return uid, ok
}

// SetScreenOwner назначает нового ведущего трансляции.
func (h *Hub) SetScreenOwner(roomID, uid string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.screenOwner[roomID] = uid
}

// ClearScreenOwner снимает ведущего трансляции.
func (h *Hub) ClearScreenOwner(roomID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	delete(h.screenOwner, roomID)
}

// ScreenStream возвращает streamId текущей трансляции экрана.
func (h *Hub) ScreenStream(roomID string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	id, ok := h.screenStream[roomID]
	return id, ok
}

// SetScreenStream запоминает streamId текущей трансляции экрана.
func (h *Hub) SetScreenStream(roomID, streamID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if streamID == "" {
		delete(h.screenStream, roomID)
		return
	}
	h.screenStream[roomID] = streamID
}

// ScreenAspect возвращает пропорции текущей трансляции экрана.
func (h *Hub) ScreenAspect(roomID string) (float64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a, ok := h.screenAspect[roomID]
	return a, ok
}

// SetScreenAspect запоминает пропорции текущей трансляции экрана.
func (h *Hub) SetScreenAspect(roomID string, aspect float64) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if aspect <= 0 {
		delete(h.screenAspect, roomID)
		return
	}
	h.screenAspect[roomID] = aspect
}

// ClearScreen снимает и ведущего, и streamId, и пропорции трансляции.
func (h *Hub) ClearScreen(roomID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	delete(h.screenOwner, roomID)
	delete(h.screenStream, roomID)
	delete(h.screenAspect, roomID)
}

// AllowStudents возвращает, разрешены ли ученикам трансляции экрана
// (по умолчанию — да).
func (h *Hub) AllowStudents(roomID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	v, ok := h.allowStudents[roomID]
	if !ok {
		return true
	}
	return v
}

// SetAllowStudents обновляет политику трансляций для учеников.
func (h *Hub) SetAllowStudents(roomID string, allow bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.allowStudents[roomID] = allow
}

// Broadcast отправляет сообщение всем участникам комнаты, кроме except.
func (h *Hub) Broadcast(roomID string, except *Client, msg []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for peer := range h.rooms[roomID] {
		if peer == except {
			continue
		}
		select {
		case peer.send <- msg:
			// отправлено
		default:
			log.Printf("room %s: клиент %s не успевает принимать, пропускаю", roomID, peer.id)
		}
	}
}
