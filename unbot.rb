require 'bundler'
require 'time'
require 'cinch'
require 'sqlite3'
require 'time_difference'

$db = SQLite3::Database.new "unbot.db"
$db.results_as_hash = true

$db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS topics (
    id int PRIMARY KEY,
    topic text UNIQUE,
    added_by text,
    untracked boolean NOT NULL DEFAULT 0
  )
SQL
$db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS mentions (
    id int PRIMARY KEY,
    topic text,
    posted_by text,
    posted_at timestamp
  )
SQL

class String
  def toNFC
    unicode_normalize(:nfc)
  end

  def toNFKC
    unicode_normalize(:nfkc)
  end

  def toNFKC_Casefold
    toNFKC.downcase
  end
end

$words = File.read("/usr/share/dict/words").split("\n").map(&:toNFKC_Casefold)

def reload!
  $topics = Set.new
  $untopics = Set.new
  $db.execute <<-SQL do |row|
    SELECT * FROM topics
  SQL
    if row["untracked"] == 1
      $untopics.add row["topic"].toNFC
    else
      $topics.add row["topic"].toNFC
    end
  end
end
reload!

bot = Cinch::Bot.new do
  configure do |c|
    c.server = "irc.freenode.org"
    c.nick = "unbot"
    c.channels = ["##whitequark"]
  end

  on :message, /^!track (.+)/ do |m, topic|
    next if !m.channel?

    if topic_nfc = $untopics.find { |t| t.toNFKC_Casefold == topic.toNFKC_Casefold }
      m.reply "not going to track '#{topic_nfc}' nope sorry", prefix: true
    elsif topic_nfc = $topics.find { |t| t.toNFKC_Casefold == topic.toNFKC_Casefold }
      m.reply "already tracking topic '#{topic_nfc}'", prefix: true
    else
      $topics.add topic.toNFC
      $db.execute <<-SQL, topic.toNFC, m.user.nick
        INSERT INTO topics (topic, added_by) VALUES (?, ?)
      SQL
      m.reply "now tracking topic '#{topic}'", prefix: true
    end
  end

  on :message, /^!untrack (.+)/ do |m, topic|
    if m.user.nick == "whitequark"
      if topic_nfc = $topics.find { |t| t.toNFKC_Casefold == topic.toNFKC_Casefold }
        $untopics.add topic_nfc
        $db.execute <<-SQL, topic_nfc do |row|
          SELECT * FROM topics WHERE topic = ?
        SQL
          m.reply "untracked topic '#{topic_nfc}' (thanks for nothing #{row['added_by']})",
                  prefix: true
        end
        $db.execute <<-SQL, topic_nfc
          UPDATE topics SET untracked = 1 WHERE topic = ?
        SQL
      else
        m.reply "not tracking topic '#{topic}'", prefix: true
      end
    else
      m.reply "you're not whitequark so no", prefix: true
    end
  end

  on :message, /^!reload$/ do |m|
    if m.user.nick == "whitequark"
      reload!
      m.reply "reloaded!", prefix: true
    end
  end

  on :message, /^!since (.+)/ do |m, topic|
    if topic_nfc = $topics.find { |t| t.toNFKC_Casefold == topic.toNFKC_Casefold }
      mentioned = false
      $db.execute <<-SQL, topic_nfc do |row|
        SELECT * FROM mentions WHERE topic = ? ORDER BY posted_at DESC LIMIT 1
      SQL
        time_passed = TimeDifference.between(Time.now, Time.parse(row["posted_at"])).humanize
        m.reply "time since last mention of '#{topic_nfc}': #{time_passed.downcase} " +
                "(mentioned by #{row["posted_by"].sub(/(.)(.)/, "\\1\u200c\\2")})", prefix: true
        mentioned = true
      end

      if !mentioned
        m.reply "no one has mentioned '#{topic_nfc}' so far", prefix: true
      end
    else
      m.reply "not tracking topic '#{topic}'", prefix: true
    end
  end

  on :message, /^\s*([^!].+)/ do |m, text|
    next if !m.channel?

    matched = Set.new
    $topics.each do |topic|
      next if $untopics.include? topic
      next if matched.include? topic.toNFKC_Casefold
      next unless text.toNFKC_Casefold.include? topic.toNFKC_Casefold

      context_ok = false
      text.toNFKC_Casefold.scan(/\w*#{Regexp.escape topic.toNFKC_Casefold}\w*/).each do |word|
        # "capture" shouldn't match "APT"
        # but, "fistulae" should match "fistula"
        next if topic.toNFKC_Casefold != word.toNFKC_Casefold &&
                ($words.include?(word.toNFKC_Casefold) && word.length > topic.length + 1)
        # "UEFI" should match "EFI" but "edefic" should not match "EFI"
        next if word.length >= 2 * topic.length
        context_ok = true
      end

      next unless context_ok

      matched.add(topic.toNFKC_Casefold)

      mentioned = false
      $db.execute <<-SQL, topic do |row|
        SELECT * FROM mentions WHERE topic = ? ORDER BY posted_at DESC LIMIT 1
      SQL
        if Time.now - Time.parse(row["posted_at"]) > 4 * 3600
          time_delta  = Time.now - Time.parse(row["posted_at"])
          time_passed = TimeDifference.between(Time.now, Time.parse(row["posted_at"])).humanize
          if topic == "69"
            m.reply "nice"
          else
            if time_delta > 3 * 86400
              flip = "*flips table*"
            else
              flip = "*flips*"
            end
            m.reply "#{flip} time since previous mention of '#{topic}': #{time_passed.downcase} " +
                    "(mentioned by #{row["posted_by"].sub(/(.)(.)/, "\\1\u200c\\2")})"
          end
        end
        mentioned = true
      end

      if !mentioned
        if topic == "69"
          m.reply "nice"
        else
          m.reply "first mention of '#{topic}'! yay!"
        end
      end

      $db.execute <<-SQL, topic, m.user.nick
        INSERT INTO mentions (topic, posted_by, posted_at) VALUES (?, ?, CURRENT_TIMESTAMP)
      SQL
    end
  end
end

bot.start
