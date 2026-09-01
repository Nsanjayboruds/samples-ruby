require 'sinatra'
require 'sinatra/json'
require 'pg'
require 'json'

# Database configuration
DB_CONFIG = {
  host: ENV['DB_HOST'] || 'localhost',
  port: ENV['DB_PORT'] || 5432,
  dbname: ENV['DB_NAME'] || 'booksdb',
  user: ENV['DB_USER'] || 'postgres',
  password: ENV['DB_PASSWORD'] || 'postgres'
}.freeze

SCHEMA_SQL = <<~SQL
  CREATE TABLE IF NOT EXISTS books (
      id SERIAL PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      author VARCHAR(255) NOT NULL,
      isbn VARCHAR(13) UNIQUE,
      published_year INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT books_published_year_check CHECK (
          published_year IS NULL OR (published_year >= 1450 AND published_year <= EXTRACT(YEAR FROM CURRENT_DATE) + 1)
      )
  );

  ALTER TABLE books ADD COLUMN IF NOT EXISTS created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
  ALTER TABLE books ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;

  CREATE TABLE IF NOT EXISTS reviews (
      id SERIAL PRIMARY KEY,
      book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
      reviewer VARCHAR(120) NOT NULL,
      rating INTEGER NOT NULL,
      comment TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT reviews_rating_check CHECK (rating >= 1 AND rating <= 5),
      CONSTRAINT reviews_comment_len_check CHECK (comment IS NULL OR char_length(comment) <= 1000)
  );

  CREATE INDEX IF NOT EXISTS idx_books_title ON books (title);
  CREATE INDEX IF NOT EXISTS idx_books_author ON books (author);
  CREATE INDEX IF NOT EXISTS idx_books_published_year ON books (published_year);
  CREATE INDEX IF NOT EXISTS idx_reviews_book_id ON reviews (book_id);
SQL

# Configure Sinatra
set :port, ENV['PORT'] || 8000
set :bind, '0.0.0.0'

# Initialize database schema on startup
begin
  startup_conn = PG.connect(DB_CONFIG)
  startup_conn.exec(SCHEMA_SQL)
  startup_conn.close
rescue PG::Error => e
  puts "Failed to initialize database schema: #{e.message}"
end

helpers do
  def db_connection
    PG.connect(DB_CONFIG)
  rescue PG::Error => e
    halt_json(500, { error: 'Database connection failed' })
  end

  def halt_json(status, payload)
    content_type :json
    halt status, payload.to_json
  end

  def parse_json_body
    body = request.body.read
    halt_json(400, { error: 'Request body is required' }) if body.to_s.strip.empty?

    JSON.parse(body)
  rescue JSON::ParserError
    halt_json(400, { error: 'Invalid JSON format' })
  end

  def valid_positive_integer?(value)
    value.to_s.match?(/\A[1-9]\d*\z/)
  end

  def parse_integer_param(raw_value, name, min: nil, max: nil, default: nil)
    return default if raw_value.nil? || raw_value.to_s.strip.empty?

    string_value = raw_value.to_s.strip
    unless string_value.match?(/\A-?\d+\z/)
      halt_json(400, { error: "#{name} must be an integer" })
    end

    value = string_value.to_i
    if min && value < min
      halt_json(400, { error: "#{name} must be >= #{min}" })
    end

    if max && value > max
      halt_json(400, { error: "#{name} must be <= #{max}" })
    end

    value
  end

  def parse_boolean_param(raw_value, name, default: false)
    return default if raw_value.nil?

    normalized = raw_value.to_s.downcase.strip
    return true if %w[1 true yes y].include?(normalized)
    return false if %w[0 false no n].include?(normalized)

    halt_json(400, { error: "#{name} must be a boolean (true/false)" })
  end

  def parse_pagination_params
    page = parse_integer_param(params['page'], 'page', min: 1, default: 1)
    per_page = parse_integer_param(params['per_page'], 'per_page', min: 1, max: 50, default: 10)

    {
      page: page,
      per_page: per_page,
      offset: (page - 1) * per_page
    }
  end

  def serialize_book(row)
    {
      id: row['id'].to_i,
      title: row['title'],
      author: row['author'],
      isbn: row['isbn'],
      published_year: row['published_year']&.to_i,
      created_at: row['created_at'],
      updated_at: row['updated_at'],
      review_count: row['review_count'] ? row['review_count'].to_i : nil,
      avg_rating: row['avg_rating'] ? row['avg_rating'].to_f : nil
    }
  end

  def serialize_review(row)
    {
      id: row['id'].to_i,
      book_id: row['book_id'].to_i,
      reviewer: row['reviewer'],
      rating: row['rating'].to_i,
      comment: row['comment'],
      created_at: row['created_at'],
      updated_at: row['updated_at']
    }
  end

  def ensure_book_exists!(conn, book_id)
    result = conn.exec_params('SELECT id FROM books WHERE id = $1', [book_id])
    halt_json(404, { error: 'Book not found' }) if result.ntuples.zero?
  end

  def ensure_unique_isbn!(conn, isbn, exclude_book_id: nil)
    return if isbn.nil? || isbn.to_s.strip.empty?

    query = 'SELECT id FROM books WHERE isbn = $1'
    params = [isbn]

    if exclude_book_id
      query += ' AND id <> $2'
      params << exclude_book_id
    end

    result = conn.exec_params(query, params)
    halt_json(400, { error: 'ISBN already exists' }) unless result.ntuples.zero?
  end

  def validate_book_payload!(payload, require_all_fields: true)
    halt_json(400, { error: 'Payload must be a JSON object' }) unless payload.is_a?(Hash)

    allowed_fields = %w[title author isbn published_year]
    unknown_fields = payload.keys - allowed_fields
    unless unknown_fields.empty?
      halt_json(400, { error: "Unknown field(s): #{unknown_fields.join(', ')}" })
    end

    if require_all_fields
      %w[title author].each do |required_key|
        if payload[required_key].to_s.strip.empty?
          halt_json(400, { error: "#{required_key.capitalize} is required" })
        end
      end
    elsif (payload.keys & allowed_fields).empty?
      halt_json(400, { error: 'At least one field must be provided for update' })
    end

    if payload.key?('title') && payload['title'].to_s.strip.empty?
      halt_json(400, { error: 'Title cannot be empty' })
    end

    if payload.key?('author') && payload['author'].to_s.strip.empty?
      halt_json(400, { error: 'Author cannot be empty' })
    end

    if payload.key?('isbn') && !payload['isbn'].nil? && payload['isbn'].to_s.length > 13
      halt_json(400, { error: 'ISBN must not exceed 13 characters' })
    end

    if payload.key?('published_year') && !payload['published_year'].nil?
      unless payload['published_year'].is_a?(Integer)
        halt_json(400, { error: 'Published year must be an integer' })
      end

      current_year_plus_one = Time.now.year + 1
      if payload['published_year'] < 1450 || payload['published_year'] > current_year_plus_one
        halt_json(400, { error: "Published year must be between 1450 and #{current_year_plus_one}" })
      end
    end
  end

  def validate_review_payload!(payload, require_all_fields: true)
    halt_json(400, { error: 'Payload must be a JSON object' }) unless payload.is_a?(Hash)

    allowed_fields = %w[reviewer rating comment]
    unknown_fields = payload.keys - allowed_fields
    unless unknown_fields.empty?
      halt_json(400, { error: "Unknown field(s): #{unknown_fields.join(', ')}" })
    end

    if require_all_fields
      %w[reviewer rating].each do |required_key|
        if payload[required_key].nil? || payload[required_key].to_s.strip.empty?
          halt_json(400, { error: "#{required_key.capitalize} is required" })
        end
      end
    elsif payload.empty?
      halt_json(400, { error: 'At least one field must be provided for review update' })
    end

    if payload.key?('reviewer') && payload['reviewer'].to_s.strip.empty?
      halt_json(400, { error: 'Reviewer cannot be empty' })
    end

    if payload.key?('rating')
      unless payload['rating'].is_a?(Integer)
        halt_json(400, { error: 'Rating must be an integer between 1 and 5' })
      end

      unless payload['rating'].between?(1, 5)
        halt_json(400, { error: 'Rating must be between 1 and 5' })
      end
    end

    if payload.key?('comment') && !payload['comment'].nil? && payload['comment'].to_s.length > 1000
      halt_json(400, { error: 'Comment must not exceed 1000 characters' })
    end
  end
end

# Health check endpoint
get '/health' do
  conn = PG.connect(DB_CONFIG)
  conn.exec('SELECT 1')
  json({ status: 'healthy', service: 'Ruby Books API', database: 'connected' })
rescue PG::Error => e
  halt_json(503, { status: 'unhealthy', service: 'Ruby Books API', database: 'disconnected' })
ensure
  conn.close if conn
end

# Get books with filtering, search, sorting, and pagination
get '/books' do
  content_type :json
  pagination = parse_pagination_params

  min_year = parse_integer_param(params['min_year'], 'min_year', min: 1450)
  max_year = parse_integer_param(params['max_year'], 'max_year', min: 1450)
  if min_year && max_year && min_year > max_year
    halt_json(400, { error: 'min_year must be less than or equal to max_year' })
  end

  sort_map = {
    'id' => 'b.id',
    'title' => 'b.title',
    'author' => 'b.author',
    'published_year' => 'b.published_year',
    'created_at' => 'b.created_at'
  }
  sort_by = params['sort_by'] || 'id'
  sort_column = sort_map[sort_by]
  unless sort_column
    halt_json(400, { error: "sort_by must be one of: #{sort_map.keys.join(', ')}" })
  end

  order = (params['order'] || 'asc').downcase
  unless %w[asc desc].include?(order)
    halt_json(400, { error: 'order must be either asc or desc' })
  end

  include_stats = parse_boolean_param(params['include_stats'], 'include_stats', default: true)

  query_params = []
  where_clauses = []

  if params['q'] && !params['q'].strip.empty?
    query_params << "%#{params['q'].strip.downcase}%"
    where_clauses << "(LOWER(b.title) LIKE $#{query_params.length} OR LOWER(b.author) LIKE $#{query_params.length})"
  end

  if params['author'] && !params['author'].strip.empty?
    query_params << "%#{params['author'].strip.downcase}%"
    where_clauses << "LOWER(b.author) LIKE $#{query_params.length}"
  end

  if min_year
    query_params << min_year
    where_clauses << "b.published_year >= $#{query_params.length}"
  end

  if max_year
    query_params << max_year
    where_clauses << "b.published_year <= $#{query_params.length}"
  end

  where_sql = where_clauses.empty? ? '' : "WHERE #{where_clauses.join(' AND ')}"

  conn = db_connection

  count_result = conn.exec_params("SELECT COUNT(*) AS total FROM books b #{where_sql}", query_params)
  total_records = count_result[0]['total'].to_i

  query_params << pagination[:per_page]
  limit_placeholder = "$#{query_params.length}"
  query_params << pagination[:offset]
  offset_placeholder = "$#{query_params.length}"

  stats_sql = if include_stats
                ', COALESCE(s.review_count, 0) AS review_count, COALESCE(s.avg_rating, 0) AS avg_rating'
              else
                ''
              end

  join_sql = if include_stats
               'LEFT JOIN (
                  SELECT book_id, COUNT(*) AS review_count, ROUND(AVG(rating)::numeric, 2) AS avg_rating
                  FROM reviews
                  GROUP BY book_id
                ) s ON s.book_id = b.id'
             else
               ''
             end

  books_result = conn.exec_params(
    "SELECT b.*#{stats_sql}
     FROM books b
     #{join_sql}
     #{where_sql}
     ORDER BY #{sort_column} #{order.upcase}
     LIMIT #{limit_placeholder}
     OFFSET #{offset_placeholder}",
    query_params
  )

  books = books_result.map { |row| serialize_book(row) }
  total_pages = (total_records.to_f / pagination[:per_page]).ceil

  json(
    books: books,
    pagination: {
      page: pagination[:page],
      per_page: pagination[:per_page],
      total_records: total_records,
      total_pages: total_pages
    }
  )
ensure
  conn.close if conn
end

# Get a specific book by ID with optional related reviews
get '/books/:id' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  include_reviews = parse_boolean_param(params['include_reviews'], 'include_reviews', default: false)

  conn = db_connection
  book_result = conn.exec_params(
    'SELECT b.*, COALESCE(s.review_count, 0) AS review_count, COALESCE(s.avg_rating, 0) AS avg_rating
     FROM books b
     LEFT JOIN (
       SELECT book_id, COUNT(*) AS review_count, ROUND(AVG(rating)::numeric, 2) AS avg_rating
       FROM reviews
       GROUP BY book_id
     ) s ON s.book_id = b.id
     WHERE b.id = $1',
    [book_id]
  )
  halt_json(404, { error: 'Book not found' }) if book_result.ntuples.zero?

  response = serialize_book(book_result[0])
  if include_reviews
    reviews_result = conn.exec_params('SELECT * FROM reviews WHERE book_id = $1 ORDER BY id', [book_id])
    response[:reviews] = reviews_result.map { |review| serialize_review(review) }
  end

  json(response)
ensure
  conn.close if conn
end

# Create a new book
post '/books' do
  content_type :json
  request_body = parse_json_body
  validate_book_payload!(request_body, require_all_fields: true)

  conn = db_connection
  ensure_unique_isbn!(conn, request_body['isbn'])
  result = conn.exec_params(
    'INSERT INTO books (title, author, isbn, published_year) VALUES ($1, $2, $3, $4) RETURNING *',
    [
      request_body['title'].strip,
      request_body['author'].strip,
      request_body['isbn'],
      request_body['published_year']
    ]
  )

  status 201
  json({ message: 'Book created successfully', book: serialize_book(result[0]) })
rescue PG::UniqueViolation
  halt_json(400, { error: 'ISBN already exists' })
ensure
  conn.close if conn
end

# Update a book fully
put '/books/:id' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  request_body = parse_json_body
  validate_book_payload!(request_body, require_all_fields: true)

  conn = db_connection
  ensure_book_exists!(conn, book_id)
  ensure_unique_isbn!(conn, request_body['isbn'], exclude_book_id: book_id)

  result = conn.exec_params(
    'UPDATE books
     SET title = $1, author = $2, isbn = $3, published_year = $4, updated_at = CURRENT_TIMESTAMP
     WHERE id = $5
     RETURNING *',
    [
      request_body['title'].strip,
      request_body['author'].strip,
      request_body['isbn'],
      request_body['published_year'],
      book_id
    ]
  )

  json({ message: 'Book updated successfully', book: serialize_book(result[0]) })
rescue PG::UniqueViolation
  halt_json(400, { error: 'ISBN already exists' })
ensure
  conn.close if conn
end

# Partial update (PATCH) a book
patch '/books/:id' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  request_body = parse_json_body
  validate_book_payload!(request_body, require_all_fields: false)

  conn = db_connection
  existing_result = conn.exec_params('SELECT * FROM books WHERE id = $1', [book_id])
  halt_json(404, { error: 'Book not found' }) if existing_result.ntuples.zero?

  existing = existing_result[0]
  title = request_body.key?('title') ? request_body['title']&.strip : existing['title']
  author = request_body.key?('author') ? request_body['author']&.strip : existing['author']
  isbn = request_body.key?('isbn') ? request_body['isbn'] : existing['isbn']
  published_year = if request_body.key?('published_year')
                     request_body['published_year']
                   else
                     existing['published_year']&.to_i
                   end

  ensure_unique_isbn!(conn, isbn, exclude_book_id: book_id)

  result = conn.exec_params(
    'UPDATE books
     SET title = $1, author = $2, isbn = $3, published_year = $4, updated_at = CURRENT_TIMESTAMP
     WHERE id = $5
     RETURNING *',
    [title, author, isbn, published_year, book_id]
  )

  json({ message: 'Book updated successfully', book: serialize_book(result[0]) })
rescue PG::UniqueViolation
  halt_json(400, { error: 'ISBN already exists' })
ensure
  conn.close if conn
end

# Delete a book
delete '/books/:id' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  conn = db_connection
  ensure_book_exists!(conn, book_id)
  conn.exec_params('DELETE FROM books WHERE id = $1', [book_id])

  json({ message: 'Book deleted successfully' })
ensure
  conn.close if conn
end

# Get reviews for a book
get '/books/:id/reviews' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  pagination = parse_pagination_params

  conn = db_connection
  ensure_book_exists!(conn, book_id)

  count_result = conn.exec_params('SELECT COUNT(*) AS total FROM reviews WHERE book_id = $1', [book_id])
  total_records = count_result[0]['total'].to_i

  result = conn.exec_params(
    'SELECT * FROM reviews WHERE book_id = $1 ORDER BY id LIMIT $2 OFFSET $3',
    [book_id, pagination[:per_page], pagination[:offset]]
  )

  reviews = result.map { |row| serialize_review(row) }
  total_pages = (total_records.to_f / pagination[:per_page]).ceil

  json(
    reviews: reviews,
    pagination: {
      page: pagination[:page],
      per_page: pagination[:per_page],
      total_records: total_records,
      total_pages: total_pages
    }
  )
ensure
  conn.close if conn
end

# Create a review for a book
post '/books/:id/reviews' do
  content_type :json
  book_id = params['id']
  halt_json(400, { error: 'Invalid ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)

  request_body = parse_json_body
  validate_review_payload!(request_body, require_all_fields: true)

  conn = db_connection
  ensure_book_exists!(conn, book_id)

  result = conn.exec_params(
    'INSERT INTO reviews (book_id, reviewer, rating, comment)
     VALUES ($1, $2, $3, $4)
     RETURNING *',
    [book_id, request_body['reviewer'].strip, request_body['rating'], request_body['comment']]
  )

  status 201
  json({ message: 'Review created successfully', review: serialize_review(result[0]) })
ensure
  conn.close if conn
end

# Partially update a review
patch '/books/:book_id/reviews/:review_id' do
  content_type :json
  book_id = params['book_id']
  review_id = params['review_id']
  halt_json(400, { error: 'Invalid book ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)
  halt_json(400, { error: 'Invalid review ID format. ID must be a positive integer' }) unless valid_positive_integer?(review_id)

  request_body = parse_json_body
  validate_review_payload!(request_body, require_all_fields: false)

  conn = db_connection
  ensure_book_exists!(conn, book_id)

  existing_result = conn.exec_params('SELECT * FROM reviews WHERE id = $1 AND book_id = $2', [review_id, book_id])
  halt_json(404, { error: 'Review not found' }) if existing_result.ntuples.zero?

  existing = existing_result[0]
  reviewer = request_body.key?('reviewer') ? request_body['reviewer']&.strip : existing['reviewer']
  rating = request_body.key?('rating') ? request_body['rating'] : existing['rating'].to_i
  comment = request_body.key?('comment') ? request_body['comment'] : existing['comment']

  result = conn.exec_params(
    'UPDATE reviews
     SET reviewer = $1, rating = $2, comment = $3, updated_at = CURRENT_TIMESTAMP
     WHERE id = $4 AND book_id = $5
     RETURNING *',
    [reviewer, rating, comment, review_id, book_id]
  )

  json({ message: 'Review updated successfully', review: serialize_review(result[0]) })
ensure
  conn.close if conn
end

# Delete a review
delete '/books/:book_id/reviews/:review_id' do
  content_type :json
  book_id = params['book_id']
  review_id = params['review_id']
  halt_json(400, { error: 'Invalid book ID format. ID must be a positive integer' }) unless valid_positive_integer?(book_id)
  halt_json(400, { error: 'Invalid review ID format. ID must be a positive integer' }) unless valid_positive_integer?(review_id)

  conn = db_connection
  ensure_book_exists!(conn, book_id)

  result = conn.exec_params('DELETE FROM reviews WHERE id = $1 AND book_id = $2 RETURNING id', [review_id, book_id])
  halt_json(404, { error: 'Review not found' }) if result.ntuples.zero?

  json({ message: 'Review deleted successfully' })
ensure
  conn.close if conn
end

# Aggregate endpoint to demo dependent calls and analytics use-cases
get '/analytics/books/top-rated' do
  content_type :json
  limit = parse_integer_param(params['limit'], 'limit', min: 1, max: 25, default: 5)
  min_reviews = parse_integer_param(params['min_reviews'], 'min_reviews', min: 1, max: 50, default: 1)

  conn = db_connection
  result = conn.exec_params(
    'SELECT b.id, b.title, b.author,
            COUNT(r.id) AS review_count,
            ROUND(AVG(r.rating)::numeric, 2) AS avg_rating
     FROM books b
     JOIN reviews r ON r.book_id = b.id
     GROUP BY b.id
     HAVING COUNT(r.id) >= $1
     ORDER BY avg_rating DESC, review_count DESC, b.id ASC
     LIMIT $2',
    [min_reviews, limit]
  )

  top_books = result.map do |row|
    {
      id: row['id'].to_i,
      title: row['title'],
      author: row['author'],
      review_count: row['review_count'].to_i,
      avg_rating: row['avg_rating'].to_f
    }
  end

  json({ books: top_books, count: top_books.length })
ensure
  conn.close if conn
end

# Error handlers
error 400 do
  json({ error: 'Bad Request' })
end

error 404 do
  json({ error: 'Not Found' })
end

error 500 do
  json({ error: 'Internal Server Error' })
end