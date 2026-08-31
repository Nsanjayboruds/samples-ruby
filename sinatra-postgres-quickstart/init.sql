-- Create the books table
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

-- Related resource table for dependent API calls
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

-- Insert sample data
INSERT INTO books (title, author, isbn, published_year) VALUES
    ('The Great Gatsby', 'F. Scott Fitzgerald', '9780743273565', 1925),
    ('To Kill a Mockingbird', 'Harper Lee', '9780061120084', 1960),
    ('1984', 'George Orwell', '9780451524935', 1949),
    ('Pride and Prejudice', 'Jane Austen', '9780141439518', 1813),
    ('The Catcher in the Rye', 'J.D. Salinger', '9780316769174', 1951)
ON CONFLICT (isbn) DO NOTHING;

INSERT INTO reviews (book_id, reviewer, rating, comment) VALUES
    (1, 'alice@example.com', 5, 'A timeless classic with vivid writing.'),
    (1, 'bob@example.com', 4, 'Great characters and atmosphere.'),
    (2, 'charlie@example.com', 5, 'Powerful themes and storytelling.'),
    (3, 'dana@example.com', 4, 'Still highly relevant today.')
ON CONFLICT DO NOTHING;
