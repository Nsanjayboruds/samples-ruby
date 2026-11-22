# Ruby + PostgreSQL API Quickstart for Keploy

This quickstart demonstrates a realistic API testing workflow with Ruby (Sinatra), PostgreSQL, and Keploy.

It goes beyond basic CRUD by including:

- Search, filtering, sorting, and pagination query patterns
- Related resources (`books` and dependent `reviews`)
- Analytics endpoint with aggregates
- Positive and negative test paths in one recording run
- Automated 20-request traffic generation script for repeatable recordings

## Prerequisites

- Docker 20.10+
- Docker Compose v2+
- Keploy CLI installed
- Linux/WSL2 (required by Keploy)

Optional local run (without Docker):

- Ruby 3.2+
- Bundler
- PostgreSQL 15+

## Project Layout

```
.
├── app.rb
├── config.ru
├── Gemfile
├── Gemfile.lock
├── Dockerfile
├── .dockerignore
├── docker-compose.yml
├── init.sql
├── run-keploy.sh
├── keploy.yml
└── README.md
```

## Run Locally (Optional)

On Ubuntu/WSL, PostgreSQL uses `peer` auth by default. Run the following to set a password and create the database over TCP:

```bash
bundle install
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"
createdb -h localhost -U postgres booksdb
psql -h localhost -U postgres -d booksdb -f init.sql
bundle exec ruby app.rb
```

Health check:

```bash
curl http://localhost:${PORT:-8000}/health
```

## Run with Docker (Recommended)

```bash
docker compose up --build
```

Then verify:

```bash
curl http://localhost:${APP_HOST_PORT:-18080}/health
```

Stop services:

```bash
docker compose down
```

If you changed schema and need a clean DB:

```bash
docker compose down -v
```

## Keploy Recording (Automated 20-call Scenario)

Run the script:

> **⚠️ Warning**: This script resets the Postgres volume on start and on exit (`docker compose down -v`). Do not run it against a database you want to keep.

```bash
./run-keploy.sh
```

What this script does:

1. Starts Keploy record mode with `docker compose up --build`
2. Selects a free host port in the `18080-18120` range unless `APP_HOST_PORT` is set
3. Waits for `/health`
4. Sends 20 API calls across list/search/filter/create/update/delete/reviews/analytics
5. Includes expected validation and conflict/not-found errors (400/409/404) to capture negative scenarios
6. Stops recording cleanly

Recorded tests are stored under `keploy/test-set-N/`.

## Keploy Replay

```bash
keploy test -c "docker compose up" --container-name "ruby-books-app" --cmd-type docker-compose --buildDelay 50 --delay 10
```

## API Endpoints

### Health

- `GET /health`

### Books

- `GET /books`
- `GET /books/:id`
- `POST /books`
- `PUT /books/:id`
- `PATCH /books/:id`
- `DELETE /books/:id`

Supported query params for `GET /books`:

- `q` (search in title/author)
- `author` (author filter)
- `min_year`, `max_year`
- `sort_by`: `id`, `title`, `author`, `published_year`, `created_at`
- `order`: `asc`, `desc`
- `page` (default: 1)
- `per_page` (default: 10, max: 50)
- `include_stats` (default: true)

For `GET /books/:id`:

- `include_reviews=true` to include dependent reviews in response

### Reviews (Dependent Resource)

- `GET /books/:id/reviews`
- `POST /books/:id/reviews`
- `PATCH /books/:book_id/reviews/:review_id`
- `DELETE /books/:book_id/reviews/:review_id`

### Analytics

- `GET /analytics/books/top-rated`

Supported query params:

- `limit` (default: 5, max: 25)
- `min_reviews` (default: 1, max: 50)

## Example Requests

Search/filter/pagination:

```bash
curl "http://localhost:${APP_HOST_PORT:-18080}/books?q=the&min_year=1900&page=1&per_page=5&sort_by=title&order=asc"
```

Create a book:

```bash
curl -X POST http://localhost:${APP_HOST_PORT:-18080}/books \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Dune",
    "author": "Frank Herbert",
    "isbn": "9780441013593",
    "published_year": 1965
  }'
```

Add a review:

```bash
curl -X POST http://localhost:${APP_HOST_PORT:-18080}/books/1/reviews \
  -H "Content-Type: application/json" \
  -d '{
    "reviewer": "qa-team@example.com",
    "rating": 5,
    "comment": "Excellent world building."
  }'
```

Analytics:

```bash
curl "http://localhost:${APP_HOST_PORT:-18080}/analytics/books/top-rated?limit=3&min_reviews=1"
```

## Troubleshooting

1. Keploy record fails to attach:

- Make sure you are on Linux/WSL2
- Ensure container name is `ruby-books-app`

2. Database schema looks stale:

- Run `docker compose down -v` and restart

3. Port conflicts:

   - **Docker run**: the app is exposed on `${APP_HOST_PORT:-18080}` (not 8000). PostgreSQL is not published to the host.
   - **Local run**: ensure ports `5432` and `${PORT:-8000}` are free.

## Notes

- This quickstart is intentionally API-focused for Keploy record/replay workflows.
- For deterministic recordings, prefer running the scripted flow instead of manual calls.