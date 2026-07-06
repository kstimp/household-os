import express from 'express';
import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const port = process.env.PORT || 3000;
const dbPath = process.env.DB_PATH || '/app/data/data.db';

// Ensure data directory exists
import fs from 'fs';
const dbDir = path.dirname(dbPath);
if (!fs.existsSync(dbDir)) {
  fs.mkdirSync(dbDir, { recursive: true });
}

const db = new Database(dbPath);

// Create tables
db.exec(`
  CREATE TABLE IF NOT EXISTS reviews (
    date TEXT PRIMARY KEY,
    balance REAL NOT NULL,
    scenario TEXT NOT NULL,
    monthly REAL NOT NULL
  );
  
  CREATE TABLE IF NOT EXISTS plans (
    name TEXT PRIMARY KEY,
    balance REAL NOT NULL,
    infl REAL NOT NULL,
    retStart REAL NOT NULL,
    retEnd REAL NOT NULL,
    cash REAL NOT NULL,
    loan REAL NOT NULL,
    loanRate REAL NOT NULL,
    residency TEXT NOT NULL,
    scenario TEXT NOT NULL,
    reviewDate TEXT NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
`);

app.use(express.json());

// Serve static assets
app.use(express.static(path.join(__dirname, '../public')));

// Reviews endpoints
app.get('/api/reviews', (req, res) => {
  try {
    const reviews = db.prepare('SELECT * FROM reviews ORDER BY date ASC').all();
    res.json(reviews);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to retrieve reviews' });
  }
});

app.post('/api/reviews', (req, res) => {
  try {
    const { date, balance, scenario, monthly } = req.body;
    if (!date || balance === undefined || !scenario || monthly === undefined) {
      return res.status(400).json({ error: 'Missing required review fields' });
    }
    const stmt = db.prepare(`
      INSERT OR REPLACE INTO reviews (date, balance, scenario, monthly)
      VALUES (?, ?, ?, ?)
    `);
    stmt.run(date, balance, scenario, monthly);
    res.status(201).json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to save review' });
  }
});

app.delete('/api/reviews/:date', (req, res) => {
  try {
    const { date } = req.params;
    const stmt = db.prepare('DELETE FROM reviews WHERE date = ?');
    const result = stmt.run(date);
    if (result.changes === 0) {
      return res.status(404).json({ error: 'Review not found' });
    }
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to delete review' });
  }
});

// Plans endpoints
app.get('/api/plans', (req, res) => {
  try {
    const plans = db.prepare('SELECT * FROM plans ORDER BY name ASC').all();
    res.json(plans);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to retrieve plans' });
  }
});

app.post('/api/plans', (req, res) => {
  try {
    const {
      name, balance, infl, retStart, retEnd,
      cash, loan, loanRate, residency, scenario, reviewDate
    } = req.body;
    
    if (!name || balance === undefined || infl === undefined || retStart === undefined ||
        retEnd === undefined || cash === undefined || loan === undefined ||
        loanRate === undefined || !residency || !scenario || !reviewDate) {
      return res.status(400).json({ error: 'Missing required plan fields' });
    }
    
    const stmt = db.prepare(`
      INSERT OR REPLACE INTO plans (
        name, balance, infl, retStart, retEnd,
        cash, loan, loanRate, residency, scenario, reviewDate, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
    `);
    
    stmt.run(
      name, balance, infl, retStart, retEnd,
      cash, loan, loanRate, residency, scenario, reviewDate
    );
    res.status(201).json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to save plan' });
  }
});

app.delete('/api/plans/:name', (req, res) => {
  try {
    const { name } = req.params;
    const stmt = db.prepare('DELETE FROM plans WHERE name = ?');
    const result = stmt.run(name);
    if (result.changes === 0) {
      return res.status(404).json({ error: 'Plan not found' });
    }
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to delete plan' });
  }
});

app.listen(port, () => {
  console.log(`College fund calculator backend listening on port ${port}`);
});
