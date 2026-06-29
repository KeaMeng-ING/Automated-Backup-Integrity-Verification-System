-- Fake PostgreSQL dump for backup_guard.sh testing (CYBR 352)
-- Not real data.
CREATE TABLE customers (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(120) NOT NULL,
    email       VARCHAR(255) UNIQUE NOT NULL,
    created_at  TIMESTAMP DEFAULT now()
);

INSERT INTO customers (name, email) VALUES
    ('Ada Lovelace',  'ada@example.com'),
    ('Alan Turing',   'alan@example.com'),
    ('Grace Hopper',  'grace@example.com');

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(id),
    total_cents INTEGER NOT NULL,
    placed_at   TIMESTAMP DEFAULT now()
);

INSERT INTO orders (customer_id, total_cents) VALUES
    (1, 4999),
    (2, 12000),
    (3, 750);
