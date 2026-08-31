FROM ruby:3.2-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy Gemfile and install dependencies
COPY Gemfile* ./
RUN bundle install

# Copy application code
COPY . .

# Expose port
EXPOSE 8000

# Start the application
CMD ["bundle", "exec", "puma", "config.ru", "-p", "8000", "-e", "production"]
