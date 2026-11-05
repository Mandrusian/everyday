import Foundation

public enum FeedCatalog {
    /// Default source pack. Every URL was fetched and parsed when this list was written; users can edit all of it.
    public static let defaults: [FeedSource] = [
        // Australia
        FeedSource(name: "ABC News", url: "https://www.abc.net.au/news/feed/51120/rss.xml", categories: [.australia, .world, .politics], trust: 3),
        FeedSource(name: "SBS News", url: "https://www.sbs.com.au/news/feed", categories: [.australia, .world], trust: 3),
        FeedSource(name: "Guardian Australia", url: "https://www.theguardian.com/australia-news/rss", categories: [.australia, .politics], trust: 3),
        FeedSource(name: "The Conversation AU", url: "https://theconversation.com/au/articles.atom", categories: [.australia, .science, .politics], trust: 3),
        FeedSource(name: "Crikey", url: "https://www.crikey.com.au/feed/", categories: [.australia, .politics], trust: 2),
        // World and politics
        FeedSource(name: "Guardian World", url: "https://www.theguardian.com/world/rss", categories: [.world, .politics], trust: 3),
        FeedSource(name: "Guardian US", url: "https://www.theguardian.com/us-news/rss", categories: [.politics, .world], trust: 3),
        FeedSource(name: "Guardian Politics", url: "https://www.theguardian.com/politics/rss", categories: [.politics], trust: 3),
        FeedSource(name: "Guardian Business", url: "https://www.theguardian.com/business/rss", categories: [.business], trust: 3),
        FeedSource(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", categories: [.world, .politics], trust: 2),
        FeedSource(name: "Democracy Now", url: "https://www.democracynow.org/democracynow.rss", categories: [.politics, .world], trust: 2),
        FeedSource(name: "The Intercept", url: "https://theintercept.com/feed/?rss", categories: [.politics, .technology], trust: 2),
        FeedSource(name: "Jacobin", url: "https://jacobin.com/feed", categories: [.politics, .business], trust: 2),
        FeedSource(name: "Mother Jones", url: "https://www.motherjones.com/feed/", categories: [.politics], trust: 2),
        // Technology and AI
        FeedSource(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", categories: [.technology, .science, .ai], trust: 3),
        FeedSource(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", categories: [.technology, .entertainment, .gaming], trust: 2),
        FeedSource(name: "Wired", url: "https://www.wired.com/feed/rss", categories: [.technology, .ai, .science], trust: 2),
        FeedSource(name: "404 Media", url: "https://www.404media.co/rss/", categories: [.technology, .ai], trust: 2),
        FeedSource(name: "MIT Technology Review", url: "https://www.technologyreview.com/feed/", categories: [.technology, .ai, .science], trust: 3),
        FeedSource(name: "IEEE Spectrum", url: "https://spectrum.ieee.org/feeds/feed.rss", categories: [.technology, .ai], trust: 3),
        FeedSource(name: "Guardian Technology", url: "https://www.theguardian.com/technology/rss", categories: [.technology, .ai], trust: 3),
        FeedSource(name: "Hacker News", url: "https://hnrss.org/frontpage", categories: [.technology, .ai], trust: 1),
        FeedSource(name: "Simon Willison", url: "https://simonwillison.net/atom/everything/", categories: [.ai, .technology], trust: 2),
        FeedSource(name: "Import AI", url: "https://importai.substack.com/feed", categories: [.ai], trust: 2),
        FeedSource(name: "Google DeepMind", url: "https://deepmind.google/blog/rss.xml", categories: [.ai, .science], trust: 3),
        // Anthropic publishes no feed of its own; these mirror its News and Research pages.
        FeedSource(name: "Anthropic News", url: "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_news.xml", categories: [.ai], trust: 3),
        FeedSource(name: "Anthropic Research", url: "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_research.xml", categories: [.ai, .science], trust: 3),
        FeedSource(name: "OpenAI News", url: "https://openai.com/news/rss.xml", categories: [.ai], trust: 3),
        FeedSource(name: "Hugging Face Blog", url: "https://huggingface.co/blog/feed.xml", categories: [.ai, .technology], trust: 2),
        FeedSource(name: "The Decoder", url: "https://the-decoder.com/feed/", categories: [.ai], trust: 2),
        // Health, climate and space
        FeedSource(name: "Guardian Health", url: "https://www.theguardian.com/society/health/rss", categories: [.health], trust: 3),
        FeedSource(name: "STAT", url: "https://www.statnews.com/feed/", categories: [.health, .science], trust: 3),
        FeedSource(name: "Guardian Environment", url: "https://www.theguardian.com/environment/rss", categories: [.climate], trust: 3),
        FeedSource(name: "Carbon Brief", url: "https://www.carbonbrief.org/feed", categories: [.climate, .science], trust: 3),
        FeedSource(name: "NASA", url: "https://www.nasa.gov/news-release/feed/", categories: [.space, .science], trust: 3),
        FeedSource(name: "Space.com", url: "https://www.space.com/feeds/all", categories: [.space], trust: 2),
        // Sport, economy and culture
        FeedSource(name: "ABC Sport", url: "https://www.abc.net.au/news/feed/2942460/rss.xml", categories: [.sport, .australia], trust: 3),
        FeedSource(name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml", categories: [.sport], trust: 3),
        FeedSource(name: "Guardian Economics", url: "https://www.theguardian.com/business/economics/rss", categories: [.economy, .business], trust: 3),
        FeedSource(name: "Dezeen", url: "https://www.dezeen.com/feed/", categories: [.design], trust: 2),
        FeedSource(name: "Pitchfork News", url: "https://pitchfork.com/feed/feed-news/rss", categories: [.music], trust: 2),
        FeedSource(name: "Guardian Film", url: "https://www.theguardian.com/film/rss", categories: [.film, .entertainment], trust: 3),
        FeedSource(name: "Guardian Books", url: "https://www.theguardian.com/books/rss", categories: [.books], trust: 3),
        FeedSource(name: "Guardian Food", url: "https://www.theguardian.com/food/rss", categories: [.food], trust: 3),
        FeedSource(name: "Guardian Travel", url: "https://www.theguardian.com/travel/rss", categories: [.travel], trust: 3),
        // Science
        FeedSource(name: "Nature", url: "https://www.nature.com/nature.rss", categories: [.science], trust: 3),
        FeedSource(name: "Quanta Magazine", url: "https://api.quantamagazine.org/feed/", categories: [.science], trust: 3),
        FeedSource(name: "New Scientist", url: "https://www.newscientist.com/feed/home/", categories: [.science], trust: 2),
        FeedSource(name: "ScienceDaily", url: "https://www.sciencedaily.com/rss/all.xml", categories: [.science], trust: 2),
        FeedSource(name: "Guardian Science", url: "https://www.theguardian.com/science/rss", categories: [.science], trust: 3),
        // Aviation
        FeedSource(name: "Simple Flying", url: "https://simpleflying.com/feed/", categories: [.aviation], trust: 2),
        FeedSource(name: "Australian Aviation", url: "https://australianaviation.com.au/feed/", categories: [.aviation, .australia], trust: 2),
        // Gaming and entertainment
        FeedSource(name: "Rock Paper Shotgun", url: "https://www.rockpapershotgun.com/feed", categories: [.gaming], trust: 2),
        FeedSource(name: "Eurogamer", url: "https://www.eurogamer.net/feed", categories: [.gaming], trust: 2),
        FeedSource(name: "Guardian Games", url: "https://www.theguardian.com/games/rss", categories: [.gaming], trust: 3),
        FeedSource(name: "Guardian Culture", url: "https://www.theguardian.com/culture/rss", categories: [.entertainment], trust: 3),
        FeedSource(name: "The A.V. Club", url: "https://www.avclub.com/rss", categories: [.entertainment], trust: 2),
        // Outside your bubble
        FeedSource(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", categories: [.world, .politics], trust: 3, outsideBubble: true),
        FeedSource(name: "NPR News", url: "https://feeds.npr.org/1001/rss.xml", categories: [.world, .politics], trust: 3, outsideBubble: true),
        FeedSource(name: "Deutsche Welle", url: "https://rss.dw.com/rdf/rss-en-all", categories: [.world, .politics, .business], trust: 3, outsideBubble: true),
    ]
}
