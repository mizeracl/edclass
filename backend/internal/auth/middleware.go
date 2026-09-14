package auth

import (
	"fmt"
	"strings"

	firebase "firebase.google.com/go/v4"
	"github.com/gofiber/fiber/v2"
	"google.golang.org/api/option"
)

type Middleware struct {
	app *firebase.App
}

func NewMiddleware(credentialsPath string) (*Middleware, error) {
	if credentialsPath == "" {
		return nil, fmt.Errorf("FIREBASE_CREDENTIALS не задан")
	}

	opt := option.WithCredentialsFile(credentialsPath)
	app, err := firebase.NewApp(nil, nil, opt)
	if err != nil {
		return nil, err
	}
	return &Middleware{app: app}, nil
}

type ContextUser struct {
	UID   string `json:"uid"`
	Email string `json:"email"`
	Role  string `json:"role"`
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

	client, err := m.app.Auth(nil)
	if err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{
			"error": "Ошибка инициализации аутентификации",
		})
	}

	// Проверяем токен
	token, err := client.VerifyIDToken(c.Context(), parts[1])
	if err != nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
			"error": "Недействительный токен",
		})
	}

	// Определяем роль из custom claims
	role, _ := token.Claims["role"].(string)
	if role == "" {
		role = "student"
	}

	c.Locals("user", ContextUser{
		UID:   token.UID,
		Email: token.Claims["email"].(string),
		Role:  role,
	})
	return c.Next()
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