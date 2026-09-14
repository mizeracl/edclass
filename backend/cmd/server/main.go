package main

import (
	"fmt"
	"log"
	"os"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/logger"

	"github.com/edclass/backend/internal/auth"
	"github.com/edclass/backend/internal/room"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	app := fiber.New(fiber.Config{
		AppName:      "EdClass API",
		ErrorHandler: customErrorHandler,
	})

	// Middleware
	app.Use(logger.New())
	app.Use(cors.New(cors.Config{
		AllowOrigins: "*",
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

	// Сигнальный сервер для видеозвонков (WebRTC).
	hub := room.NewHub()
	app.Get("/ws/meetings/:meetingId", room.NewSignalingHandler(hub))

	// Auth middleware (Firebase)
	// ВАЖНО: файл service account скачивается из Firebase Console:
	//   Project settings → Service accounts → Generate new private key
	// И в env: FIREBASE_CREDENTIALS=/path/to/key.json
	authMiddleware, err := auth.NewMiddleware(os.Getenv("FIREBASE_CREDENTIALS"))
	if err != nil {
		log.Printf("⚠️  Firebase auth не подключён: %v", err)
		log.Printf("   Сервер работает без авторизации. Укажите FIREBASE_CREDENTIALS.")
	}

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
				"hint":   "Укажите FIREBASE_CREDENTIALS для активации",
			})
		})
	}

	fmt.Printf("🚀 EdClass API server starting on port %s\n", port)
	log.Fatal(app.Listen(":" + port))
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