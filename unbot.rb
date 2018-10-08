require 'bundler'
require 'time'
require 'cinch'
require 'sqlite3'
require 'time_difference'

db = SQLite3::Database.new "unbot.db"
db.results_as_hash = true

db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS topics (
    id int PRIMARY KEY,
    topic text UNIQUE,
    added_by text
  )
SQL
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS mentions (
    id int PRIMARY KEY,
    topic text,
    posted_by text,
    posted_at timestamp
  )
SQL

topics = []
db.execute <<-SQL do |row|
  SELECT * FROM topics
SQL
  topics.push row["topic"]
end

bot = Cinch::Bot.new do
  configure do |c|
    c.server = "irc.freenode.org"
    c.nick = "unbot"
    c.channels = ["##bottorture"]
  end

  on :message, /^!track (.+)/ do |m, topic|
    if topics.include? topic
      m.reply "already tracking topic '#{topic}'", prefix: true
    else
      topics.push topic
      db.execute <<-SQL, topic, m.user.nick
        INSERT INTO topics (topic, added_by) VALUES (?, ?)
      SQL
      m.reply "now tracking topic '#{topic}'", prefix: true
    end
  end

  on :message, /^!since (.+)/ do |m, topic|
    if topics.include? topic
      mentioned = false
      db.execute <<-SQL, topic do |row|
        SELECT * FROM mentions WHERE topic = ? ORDER BY posted_at DESC LIMIT 1
      SQL
        time_passed = TimeDifference.between(Time.now, Time.parse(row["posted_at"])).humanize
        m.reply "time since last mention of '#{topic}': #{time_passed.downcase} " +
                "(mentioned by #{row["posted_by"]})", prefix: true
        mentioned = true
      end

      if !mentioned
        m.reply "no one has mentioned '#{topic}' so far", prefix: true
      end
    else
      m.reply "not tracking topic '#{topic}'", prefix: true
    end
  end

  on :message, /^\s*([^!].+)/ do |m, text|
    topics.each do |topic|
      if text.include? topic
        mentioned = false
        db.execute <<-SQL, topic do |row|
          SELECT * FROM mentions WHERE topic = ? ORDER BY posted_at DESC LIMIT 1
        SQL
          if Time.now - Time.parse(row["posted_at"]) > 4 * 3600
            time_passed = TimeDifference.between(Time.now, Time.parse(row["posted_at"])).humanize
            m.reply "*flips* time since previous mention of '#{topic}': #{time_passed.downcase} " +
                    "(mentioned by #{row["posted_by"]})"
          end
          mentioned = true
        end

        if !mentioned
          m.reply "first mention of '#{topic}'! yay!"
        end

        db.execute <<-SQL, topic, m.user.nick
          INSERT INTO mentions (topic, posted_by, posted_at) VALUES (?, ?, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end
end

bot.start
