package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/limiter"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/gofiber/fiber/v2/middleware/recover"

	"github.com/edclass/backend/internal/auth"
	"github.com/edclass/backend/internal/room"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// ENFORCE_AUTH=1 — прод-режим: без FIREBASE_CREDENTIALS сервер НЕ
	// стартует, а падает с понятным сообщением. Это страховая от «тихого»
	// запуска без авторизации (когда сервер работает, а все маршруты
	// открыты, потому что dev-fallback остался включённым).
	if os.Getenv("ENFORCE_AUTH") == "1" && os.Getenv("FIREBASE_CREDENTIALS") == "" {
		log.Fatal("ENFORCE_AUTH=1, но FIREBASE_CREDENTIALS не задан. " +
			"Запуск запрещён: сервер не будет работать без авторизации.")
	}

	app := fiber.New(fiber.Config{
		AppName:      "EdClass API",
		ErrorHandler: customErrorHandler,
	})

	// recover ловит паники в любом хендлере и превращает их в 500, а не в
	// падение всего процесса. Без него любой неожиданный panic (например,
	// нестандартный токен или некорректный payload) ронял бы сервер целиком —
	// тривиальный способ «положить» API одним запросом.
	app.Use(recover.New())

	// Middleware
	app.Use(logger.New())

	// Rate-limit: защита и от брутфорса токенов (классический поток
	// «401/401/401» по каждому подставному /api/protected и WS-подключению),
	// и от шторма переподключений в сигнальный сервер. Лимит на IP.
	app.Use(limiter.New(limiter.Config{
		Max:        60,              // запросов
		Expiration: 1 * time.Minute, // за период
		KeyGenerator: func(c *fiber.Ctx) string {
			return c.IP()
		},
		LimitReached: func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error": "Слишком много запросов, подождите",
			})
		},
	}))

	// CORS: в production задаётся явный список через CORS_ORIGINS
	// (https://app.edclass.ru,https://admin.edclass.ru — через запятую).
	// "*" остаётся только как dev-fallback, когда CORS_ORIGINS не задан.
	app.Use(cors.New(cors.Config{
		AllowOrigins: corsOrigins(),
		AllowMethods: "GET,POST,PUT,PATCH,DELETE,OPTIONS",
		AllowHeaders: "Origin,Content-Type,Authorization",
	}))

	// Health check
	app.Get("/health", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"status":  "ok",
			"service": "EdClass API",
		})
	})

	// Auth middleware (Firebase)
	// ВАЖНО: файл service account скачивается из Firebase Console:
	//   Project settings → Service accounts → Generate new private key
	// И в env: FIREBASE_CREDENTIALS=/path/to/key.json
	authMiddleware, err := auth.NewMiddleware(os.Getenv("FIREBASE_CREDENTIALS"))
	if err != nil {
		log.Printf("⚠️  Firebase auth не подключён: %v", err)
		log.Printf("   Сервер работает без авторизации. Укажите FIREBASE_CREDENTIALS.")
	}

	// Сигнальный сервер для видеозвонков (WebRTC).
	// Личность участника НЕ берётся из query (uid/name/teacher клиент
	// подделывает одной строкой): при работающем Firebase личность получается
	// из проверенного ID-токена + Firestore-профиля, и только при его
	// отсутствии (dev без FIREBASE_CREDENTIALS) — упрощённый fallback.
	hub := room.NewHub()
	var wsVerify room.TokenVerifier
	if authMiddleware != nil {
		wsVerify = func(rawToken string) (room.Identity, error) {
			user, err := authMiddleware.Verify(context.Background(), rawToken)
			if err != nil {
				return room.Identity{}, err
			}
			return room.Identity{
				UID:  user.UID,
				Name: user.Name,
				Role: user.Role,
			}, nil
		}
	} else {
		log.Println("⚠️  WS-сигналинг без проверки токена (dev-реuжим): достаточно установить FIREBASE_CREDENTIALS")
	}
	app.Get("/ws/meetings/:meetingId", room.NewSignalingHandler(hub, wsVerify))

	// api routes
	api := app.Group("/api")

	if authMiddleware != nil {
		api.Get("/protected/example", authMiddleware.Protected, func(c *fiber.Ctx) error {
			user := auth.GetUser(c)
			return c.JSON(fiber.Map{
				"message": "Защищённый эндпоинт",
				"user":    user,
			})
		})

		// Примеры использования
		// api.Post("/meetings", authMiddleware.Protected, authMiddleware.TeacherOnly, handler)
	} else {
		api.Get("/protected/example", func(c *fiber.Ctx) error {
			return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{
				"error": "Аутентификация не настроена",
				"hint":  "Укажите FIREBASE_CREDENTIALS для активации",
			})
		})
	}

	fmt.Printf("🚀 EdClass API server starting on port %s\n", port)
	log.Fatal(app.Listen(":" + port))
}

// corsOrigins возвращает белый список источников для CORS из env
// CORS_ORIGINS (разделитель — запятая). Если не задан — "*" (dev-fallback).
func corsOrigins() string {
	if origins := os.Getenv("CORS_ORIGINS"); origins != "" {
		return strings.Join(strings.Split(origins, ","), ",")
	}
	return "*"
}

func customErrorHandler(c *fiber.Ctx, err error) error {
	code := fiber.StatusInternalServerError
	if e, ok := err.(*fiber.Error); ok {
		code = e.Code
	}
	return c.Status(code).JSON(fiber.Map{
		"error": err.Error(),
	})
}
