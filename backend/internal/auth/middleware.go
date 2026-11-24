package auth

import (
	"context"
	"fmt"
	"strings"
	"sync"

	firestore "cloud.google.com/go/firestore"
	firebase "firebase.google.com/go/v4"
	"github.com/gofiber/fiber/v2"
	"google.golang.org/api/option"
)

type Middleware struct {
	app *firebase.App

	// Firestore-клиент создаётся лениво и переиспользуется: он нужен, чтобы
	// брать роль из доверенного профиля users/{uid}, а не из подделываемого
	// query. Один клиент на весь процесс — так положено Admin SDK.
	fsOnce   sync.Once
	fsClient *firestore.Client
	fsErr    error
}

// ContextUser — доверенные данные пользователя, извлечённые из проверенного
// Firebase токена и Firestore-профиля. Используются и REST-мидлварой, и
// WebSocket-сигналингом — везде, где uid/роль не должны зависеть от битых
// query-параметров, которые клиент подделывает одной строкой.
type ContextUser struct {
	UID   string
	Email string
	Name  string
	Role  string
}

func NewMiddleware(credentialsPath string) (*Middleware, error) {
	if credentialsPath == "" {
		return nil, fmt.Errorf("FIREBASE_CREDENTIALS не задан")
	}

	opt := option.WithCredentialsFile(credentialsPath)
	app, err := firebase.NewApp(context.Background(), nil, opt)
	if err != nil {
		return nil, err
	}
	return &Middleware{app: app}, nil
}

// Protected проверяет JWT токен Firebase и подставляет пользователя в контекст.
func (m *Middleware) Protected(c *fiber.Ctx) error {
	header := c.Get("Authorization")
	if header == "" {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Отсутствует токен авторизации",
		})
	}

	// Формат: "Bearer <token>"
	parts := strings.Split(header, " ")
	if len(parts) != 2 || parts[0] != "Bearer" {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Неверный формат токена. Ожидается: Bearer <token>",
		})
	}

	user, err := m.verifyToken(c.Context(), parts[1])
	if err != nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Недействительный токен",
		})
	}

	c.Locals("user", user)
	return c.Next()
}

// Verify проверяет сырой Firebase ID-токен вне HTTP-запроса — то есть именно
// там, где нет заголовков: WebSocket-сигналинг получает токен строкой из URL.
// Возвращает доверенного пользователя; uid и роль берутся строго из
// проверенного токена и Firestore-профиля, а не из подделываемых query-параметров.
func (m *Middleware) Verify(ctx context.Context, rawToken string) (ContextUser, error) {
	return m.verifyToken(ctx, rawToken)
}

// verifyToken — общий внутренний путь проверки токена. Используется и REST
// (Protected), и WebSocket-сигналингом (Verify), чтобы поведение было
// одинаковым и не расходилось со временем.
func (m *Middleware) verifyToken(ctx context.Context, rawToken string) (ContextUser, error) {
	client, err := m.app.Auth(ctx)
	if err != nil {
		return ContextUser{}, err
	}

	// Проверяем токен: uid берём только из проверенного Firebase токена.
	idToken, err := client.VerifyIDToken(ctx, rawToken)
	if err != nil {
		return ContextUser{}, err
	}

	// Роль: сначала custom claims от Firebase, иначе — доверенный профиль в
	// Firestore users/{uid}.role, иначе «student». Custom claims вправе
	// технически быть установлены с большими правами — их ставит только
	// сервер (см. setRole). Профиль — источник для ролей, которые назначены
	// вручную/через админку, поэтому он дороже любой query-строки.
	role, _ := idToken.Claims["role"].(string)
	if role == "" {
		role = m.firestoreRole(ctx, idToken.UID)
	}
	if role == "" {
		role = "student"
	}

	// Email и имя могут отсутствовать у токенов, выпущенных для провайдеров
	// без e-mail (телефон/анонимная регистрация). Comma-ok обязателен: без
	// него один неосторожный каст ронял бы весь процесс (DoS одним токеном).
	email, _ := idToken.Claims["email"].(string)
	name, _ := idToken.Claims["name"].(string)

	return ContextUser{
		UID:   idToken.UID, // СТРОГО из проверенного токена
		Email: email,
		Name:  name,
		Role:  role,
	}, nil
}

// firestoreRole достаёт роль из доверенного профиля users/{uid}.role (Admin SDK).
func (m *Middleware) firestoreRole(ctx context.Context, uid string) string {
	client, err := m.firestoreClient(ctx)
	if err != nil {
		return ""
	}

	doc, err := client.Collection("users").Doc(uid).Get(ctx)
	if err != nil {
		// Профиля ещё нет (первый вход) — роли не назначено, вернём empty,
		// и её подставит дефолт «student». Это не ошибка авторизации.
		return ""
	}

	role, _ := doc.Data()["role"].(string)
	return role
}

// firestoreClient лениво создаёт Firestore-клиент и переиспользует его
// между запросами (создание клиента на каждый запрос — дорого и течёт).
func (m *Middleware) firestoreClient(ctx context.Context) (*firestore.Client, error) {
	m.fsOnce.Do(func() {
		m.fsClient, m.fsErr = m.app.Firestore(ctx)
	})
	return m.fsClient, m.fsErr
}

// TeacherOnly разрешает доступ только учителям.
func (m *Middleware) TeacherOnly(c *fiber.Ctx) error {
	user := c.Locals("user").(ContextUser)
	if user.Role != "teacher" {
		return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
			"error": "Доступ разрешён только учителям",
		})
	}
	return c.Next()
}

// GetUser достаёт текущего пользователя из контекста.
func GetUser(c *fiber.Ctx) ContextUser {
	if user, ok := c.Locals("user").(ContextUser); ok {
		return user
	}
	return ContextUser{}
}
