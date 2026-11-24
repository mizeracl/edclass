package room

import (
	"encoding/json"
	"log"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/websocket/v2"
)

// Identity — доверенная личность участника, установленная верификатором
// auth (проверенный Firebase токен + Firestore-профиль). Пакет room намеренно
// не импортирует internal/auth: проверка инжектируется снаружи из main.
type Identity struct {
	UID  string
	Name string
	Role string
}

// TokenVerifier проверяет сырой Firebase ID-токен (пришедший строкой в query
// у WebSocket) и возвращает доверенную личность. Если токен невалиден —
// соединение отклоняется ещё до добавления в комнату.
type TokenVerifier func(rawToken string) (Identity, error)

// NewSignalingHandler создаёт WebSocket-обработчик комнаты встречи.
//
// URL:  GET /ws/meetings/:meetingId?token=<firebaseIdToken>
// Сервер назначает роли offerer/answerer, следит за одиночной трансляцией
// экрана (и приоритетом учителя перед учениками) и ретранслирует
// SDP/ICE и служебные пакеты между участниками.
//
// verify может быть nil — тогда (только в dev без FIREBASE_CREDENTIALS)
// личность берётся из query uid/name/teacher, чтобы сигналинг работал без
// реального Firebase. В проде verify обязан быть непустым, иначе клиент,
// подделавший одну строку ?uid=...&teacher=1, получил бы чужой кабинет.
func NewSignalingHandler(hub *Hub, verify TokenVerifier) fiber.Handler {
	return websocket.New(func(c *websocket.Conn) {
		meetingID := c.Params("meetingId")

		var (
			uid       string
			name      string
			isTeacher bool
		)

		if verify != nil {
			// Идентичность — СТРОГО из проверенного токена. query с uid/name/
			// teacher здесь игнорируется: его клиент подделывает одной строкой.
			ident, err := verify(c.Query("token"))
			if err != nil {
				_ = c.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.ClosePolicyViolation,
						"Невалидный токен авторизации"))
				return
			}
			uid = ident.UID
			name = ident.Name
			role := ident.Role
			if role == "" {
				role = "student"
			}
			isTeacher = role == "teacher"
		} else {
			// Dev-fallback без Firebase: роль из query. Небезопасно, поэтому
			// возможен только когда сервер запущен без credentials (см. main).
			uid = c.Query("uid")
			name = c.Query("name")
			isTeacher = c.Query("teacher") == "1"
		}

		if meetingID == "" || uid == "" {
			_ = c.WriteMessage(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "meetingId и uid обязательны"))
			return
		}

		client := hub.AddClient(uid, meetingID, name, isTeacher)
		defer hub.RemoveClient(client)

		log.Printf("👤 %s (%s) вошёл в комнату %s (%s)", uid, name, meetingID, client.role)

		// Сообщаем клиенту его роль.
		if err := send(c, Message{Type: TypeJoined, From: uid, Role: client.role}); err != nil {
			return
		}

		// Текущая политика «можно ли ученикам показывать экран».
		_ = send(c, Message{Type: TypePolicy, From: "server", Allow: hub.AllowStudents(meetingID)})

		// Рассказываем уже сидящим в комнате, что появился новый участник.
		hub.Broadcast(meetingID, client, mustMarshal(Message{
			Type: TypePeerJoin,
			From: uid,
			Name: client.name,
		}))

		// А новому участнику — список тех, кто уже в комнате (с именами).
		names := hub.PeerNames(meetingID, client)
		if len(names) > 0 {
			if err := send(c, Message{Type: TypePeers, From: "server", Names: names}); err != nil {
				return
			}
		}

		// Кто сейчас ведёт трансляцию — сообщаем новичку до начала переговоров,
		// иначе он не сможет отличить экран собеседника от его камеры.
		if ownerID, ok := hub.ScreenOwner(meetingID); ok {
			streamID, _ := hub.ScreenStream(meetingID)
			aspect, _ := hub.ScreenAspect(meetingID)
			if cur := hub.FindClient(meetingID, ownerID); cur != nil {
				if err := send(c, Message{
					Type:     TypeScreen,
					From:     ownerID,
					Name:     cur.name,
					Active:   true,
					StreamID: streamID,
					Aspect:   aspect,
				}); err != nil {
					return
				}
			}
		}

		// Держим соединение живым пингами. Браузер сам отвечает на ping, и если
		// сеть оборвалась «молча» (без закрытия), через pongDeadline чтение
		// вернёт ошибку — и «призрак» участника покинет комнату. Без этого
		// собеседник навсегда остался бы с застывшей картинкой и сломанным
		// переподключением.
		//
		// ПИНГ пишется ТОЛЬКО из того же цикла записи, что и данные: gorilla
		// запрещает писать в WebSocket из нескольких горутин одновременно —
		// параллельная запись ломает кадры и роняет соединение.
		const pongDeadline = 90 * time.Second
		c.SetPongHandler(func(string) error {
			return c.SetReadDeadline(time.Now().Add(pongDeadline))
		})
		pingTicker := time.NewTicker(30 * time.Second)
		defer pingTicker.Stop()

		// Канал записи: цикл пишет и данные, и пинги по очереди.
		// ФоновАЯ горутина — а отдельная потому, что для соединения нужен
		// сразу и читающий, и пишущий цикл (см. ниже главный read-loop).
		// fiber-recover-мидлвара НЕ покрывает дочерние горутины: паника
		// всплыла бы в main-горутине fiber и уронила бы весь процесс. Поэтому
		// вешаем свой recover — ибо в WS-цикле паники бывают (нестандартный
		// кадр, кадр с переполненным заголовком), и ценой одной паники
		// собеседник должен получить закрытое соединение, а не весь сервер.
		writeStop := make(chan struct{})
		done := make(chan struct{})
		startWriteLoop := func() {
			// done закрывается и при нормальном выходе, и при выходе после
			// паники: по нему основной read-loop (после <readDone> внизу)
			// понимает, что писать некому, и больше не ждёт нас — иначе
			// при панике держал бы соединение «на весу» до самого pongDeadline.
			defer close(done)
			defer func() {
				if r := recover(); r != nil {
					log.Printf("room %s: паника в write-loop клиента %s: %v — закрываю соединение",
						meetingID, uid, r)
					_ = c.WriteMessage(websocket.CloseMessage,
						websocket.FormatCloseMessage(websocket.CloseAbnormalClosure,
							"Внутренняя ошибка сервера"))
				}
			}()
			for {
				select {
				case msg := <-client.send:
					_ = c.SetWriteDeadline(time.Now().Add(10 * time.Second))
					if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
						return
					}
				case <-pingTicker.C:
					_ = c.SetWriteDeadline(time.Now().Add(10 * time.Second))
					if err := c.WriteMessage(websocket.PingMessage, nil); err != nil {
						return
					}
				case <-writeStop:
					return
				}
			}
		}
		go startWriteLoop()

		// Читаем входящие сообщения. Лимит размера большой: offer после
		// включения экрана (звук + камера + экран) легко превышает 4 КБ,
		// и слишком маленький лимит ронял соединение как раз в момент
		// очередного offer — получался бесконечный цикл переподключений.
		left := false
		for {
			_ = c.SetReadDeadline(time.Now().Add(pongDeadline))
			_, data, err := c.ReadMessage()
			if err != nil {
				log.Printf("room %s: клиент %s закрыл соединение: %v", meetingID, uid, err)
				break
			}
			// Пока это соединение ещё участник комнаты? Если его заменило новое
			// (тот же uid переподключился с другого устройства) — старый
			// websocket больше не ретранслируем: его сообщения могут нести
			// устаревшие offer/ice и сбивать настоящего собеседника.
			if client.superseded {
				log.Printf("room %s: клиент %s заменён новым соединением, старый закрыт",
					meetingID, uid)
				break
			}
			if err != nil {
				break
			}

			var m Message
			if err := json.Unmarshal(data, &m); err != nil {
				continue
			}

			switch m.Type {
			case TypeLeave:
				left = true
			case TypeOffer, TypeAnswer, TypeIce, TypeDevice, TypeRenegotiate, TypeDraw,
				TypeChat, TypeReaction, TypeBoardImage:
				m.From = uid
				if m.Type == TypeIce {
					log.Printf("room %s: relaying ice from %s (payload=%d bytes)",
						meetingID, uid, len(data))
				}
				hub.Broadcast(meetingID, client, mustMarshal(m))
			case TypeScreen:
				handleScreen(hub, meetingID, client, m)
			case TypePolicy:
				handlePolicy(hub, meetingID, client, m)
			default:
				// Игнорируем неизвестные типы.
			}
		}

		// Сообщаем оставшимся, что участник покинул комнату — намеренно или
		// из-за обрыва/перезагрузки страницы. Без этого у собеседника
		// остаётся «застывшая» картинка и рассинхронизированные роли.
		// Заменённое соединение (переподключение того же uid) молчит:
		// новое уже объявило себя через peer-join.
		if !left && !client.superseded {
			hub.Broadcast(meetingID, client, mustMarshal(Message{
				Type: TypePeerLeave,
				From: uid,
			}))
		}

		// Если уходил ведущий трансляции — снимаем его экран у всех.
		if !client.superseded {
			if owner, ok := hub.ScreenOwner(meetingID); ok && owner == uid {
				hub.ClearScreen(meetingID)
				hub.Broadcast(meetingID, client, mustMarshal(Message{
					Type:   TypeScreen,
					From:   "server",
					Active: false,
					Forced: true,
				}))
			}
		}
		hub.RemoveClient(client)
		close(writeStop)
		<-done
	})
}

// handleScreen поддерживает ОДНУ активную трансляцию экрана на комнату:
//   - остановка трансляции обрабатывается только от её владельца;
//   - новый ведущий «снимает» прежнего (тому уходит принудительный стоп) —
//     и ученик может перехватить у учителя, и наоборот;
//   - ученик не может начать трансляцию, если учитель её запретил.
func handleScreen(hub *Hub, meetingID string, client *Client, m Message) {
	if !m.Active {
		// Остановка трансляции: ретранслируем только от текущего владельца.
		if owner, ok := hub.ScreenOwner(meetingID); ok && owner == client.id {
			hub.ClearScreen(meetingID)
			hub.Broadcast(meetingID, client, mustMarshal(m))
		}
		return
	}

	// Попытка начать трансляцию. В ретранслируемое сообщение кладём From и
	// streamId, чтобы собеседнику было проще отличить экран от камеры.
	m.From = client.id

	ownerID, hasOwner := hub.ScreenOwner(meetingID)
	if hasOwner && ownerID != client.id && !client.isTeacher && !hub.AllowStudents(meetingID) {
		// Учитель запретил ученикам показывать экран.
		_ = hub.SendTo(client, mustMarshal(Message{Type: TypeShareDenied, From: "server", Allow: false}))
		return
	}

	switch {
	case !hasOwner:
		// Свободно — становишься ведущим.
		hub.SetScreenOwner(meetingID, client.id)
		hub.SetScreenStream(meetingID, m.StreamID)
	case ownerID == client.id:
		// Повторный запрос от действующего ведущего (например, после
		// перегрузки имя потока могло измениться) — ретранслируем.
		hub.SetScreenStream(meetingID, m.StreamID)
	default:
		// Трансляция занята другим — снимаем прежнего ведущего и передаём
		// трансляцию новому (одиночная трансляция).
		if cur := hub.FindClient(meetingID, ownerID); cur != nil {
			_ = hub.SendTo(cur, mustMarshal(Message{
				Type:   TypeScreen,
				From:   "server",
				Active: false,
				Forced: true,
			}))
		}
		hub.SetScreenOwner(meetingID, client.id)
		hub.SetScreenStream(meetingID, m.StreamID)
	}
	hub.SetScreenAspect(meetingID, m.Aspect)

	hub.Broadcast(meetingID, client, mustMarshal(m))
}

// handlePolicy обрабатывает переключатель «разрешить ученикам показ экрана».
func handlePolicy(hub *Hub, meetingID string, client *Client, m Message) {
	if !client.isTeacher {
		return // менять политику может только учитель
	}
	hub.SetAllowStudents(meetingID, m.Allow)

	if !m.Allow {
		// Если прямо сейчас экран показывает ученик — снимаем его.
		if owner, ok := hub.ScreenOwner(meetingID); ok {
			if cur := hub.FindClient(meetingID, owner); cur != nil && !cur.isTeacher {
				_ = hub.SendTo(cur, mustMarshal(Message{
					Type:   TypeScreen,
					From:   "server",
					Active: false,
					Forced: true,
				}))
				hub.ClearScreen(meetingID)
				// Остальные тоже снимают его экран (уходит «стоп»).
				hub.Broadcast(meetingID, cur, mustMarshal(Message{
					Type:   TypeScreen,
					From:   "server",
					Active: false,
				}))
			}
		}
	}

	// Ретранслируем новую политику остальным участникам.
	m.From = client.id
	hub.Broadcast(meetingID, client, mustMarshal(m))
}

func send(c *websocket.Conn, m Message) error {
	return c.WriteMessage(websocket.TextMessage, mustMarshal(m))
}

func mustMarshal(m Message) []byte {
	data, err := json.Marshal(m)
	if err != nil {
		log.Printf("❌ marshal error: %v", err)
		return nil
	}
	return data
}
