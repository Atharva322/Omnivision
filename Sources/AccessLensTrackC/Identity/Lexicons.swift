//
//  Lexicons.swift
//  Track C — two small compiled-in word sets used by `PortableNameValidator`.
//
//  Neither is a model and neither is exhaustive; they are compiled in rather than shipped as
//  resources so that they cannot fail to load. `GivenNameLexicon` raises confidence, it never
//  gates: a name that is not in it can still bind from a strong template, because a 300-entry list
//  would otherwise be a hard ceiling on whose name this product is able to learn.
//

import Foundation

/// Given names spanning several linguistic backgrounds. Membership is a *positive* signal only.
///
/// Deliberately not a gate. If this list were required, the system would fail exactly the people it
/// is least acceptable to fail. Entries are stored normalised (lowercase, diacritics folded).
public enum GivenNameLexicon {

    public static func contains(_ normalizedToken: String) -> Bool {
        names.contains(normalizedToken)
    }

    /// Number of entries, reported by the evaluation tool so the list's size is never overstated.
    public static var count: Int { names.count }

    static let names: Set<String> = [
        // English / Western European
        "aaron", "abigail", "adam", "adrian", "alan", "albert", "alex", "alexander", "alice",
        "alison", "amanda", "amelia", "amy", "andrew", "angel", "angela", "ann", "anna", "anne", "anthony",
        "april", "arthur", "art", "august", "barbara", "ben", "benjamin", "beth", "bill", "bob",
        "brian", "bruce", "caroline", "catherine", "charles", "charlotte", "chase", "chris",
        "christine", "christopher", "claire", "clara", "colin", "craig", "daniel", "danielle",
        "dave", "david", "dawn", "dean", "deborah", "dennis", "diana", "donald", "donna",
        "dorothy", "douglas", "drew", "earl", "edward", "eleanor", "elizabeth", "ellen", "emily",
        "emma", "eric", "evelyn", "faith", "fiona", "frances", "frank", "george", "grace",
        "graham", "gregory", "hannah", "harold", "harry", "heather", "helen", "henry", "holly",
        "hope", "howard", "hunter", "ian", "isaac", "jack", "jacob", "james", "jane", "janet",
        "jason", "jean", "jeffrey", "jennifer", "jeremy", "jessica", "joan", "joe", "john",
        "jonathan", "jordan", "joseph", "joshua", "joy", "juliet", "julia", "june", "justin",
        "karen", "kate", "katherine", "keith", "kelly", "kenneth", "kevin", "kim", "laura",
        "lauren", "lawrence", "linda", "lisa", "liam", "louise", "lucy", "luke", "margaret",
        "maria", "marcus", "mark", "martin", "mary", "matthew", "may", "megan", "melissa",
        "michael", "michelle", "miles", "nancy", "naomi", "natalie", "nathan", "neil", "nicholas",
        "nicole", "noah", "norman", "oliver", "olivia", "oscar", "patricia", "patrick", "paul",
        "paula", "peter", "philip", "rachel", "ralph", "raymond", "rebecca", "reed", "rich",
        "richard", "robert", "roger", "ronald", "rose", "roy", "ruth", "ryan", "samuel", "sandra",
        "sarah", "scott", "sean", "sharon", "shirley", "simon", "sophie", "stephen", "steven",
        "stuart", "summer", "sunny", "susan", "teresa", "theresa", "thomas", "timothy", "tom",
        "tracy", "victoria", "vincent", "walter", "wayne", "wendy", "will", "william", "zoe",
        "beverly", "kimberly", "molly", "sally", "carly", "ashley", "haley", "riley",
        "bradley", "stanley", "wesley", "shelly",

        // Irish / Scottish / Welsh
        "aiden", "aoife", "brendan", "bridget", "callum", "ciara", "declan", "eoin", "fergus",
        "gwen", "hamish", "kieran", "lachlan", "liadh", "maeve", "niamh", "oisin", "rhys",
        "roisin", "ronan", "saoirse", "seamus", "sinead", "siobhan",

        // Southern / Eastern European
        "alessandro", "aleksandr", "ana", "andrei", "anastasia", "bianca", "bogdan", "camila",
        "carlos", "carmen", "cristina", "dario", "dmitri", "dominik", "elena", "esteban",
        "francesca", "gabriel", "giulia", "gonzalo", "ivan", "javier", "jorge", "jose", "juan",
        "katarzyna", "lucia", "luis", "magda", "marek", "mateo", "matteo", "milena", "natasha",
        "nikola", "olga", "pablo", "paolo", "pedro", "petra", "rafael", "ricardo", "rosa",
        "sergei", "sofia", "sophia", "svetlana", "tomas", "valentina", "vladimir", "zoltan",

        // Nordic / Germanic / Dutch
        "anders", "annika", "astrid", "bjorn", "dirk", "elin", "erik", "freya", "gerd", "greta",
        "hans", "ingrid", "jens", "johan", "jonas", "karl", "katrin", "klaus", "lars", "lena",
        "lukas", "magnus", "maren", "mathilde", "nils", "oskar", "pieter", "sanne", "sigrid",
        "sven", "thijs", "ulrich", "wouter",

        // South Asian
        "aditya", "ajay", "akash", "amit", "ananya", "anil", "anita", "anjali", "arjun", "arun",
        "asha", "deepak", "divya", "gita", "harpreet", "indira", "ishaan", "jaya", "kavita",
        "kiran", "krishna", "lakshmi", "manoj", "meera", "mohan", "neha", "nikhil", "nisha",
        "pooja", "prakash", "pranav", "priya", "rahul", "raj", "rajesh", "ravi", "rekha", "riya",
        "rohan", "rohit", "sanjay", "shreya", "sunita", "suresh", "tara", "vikram", "vijay",
        "vishal",

        // East / Southeast Asian
        "akira", "aiko", "bao", "chen", "daiki", "haru", "hana", "hiroshi", "hyun", "jae", "jin",
        "jing", "jun", "kaito", "keiko", "kenji", "kim", "lan", "lei", "li", "lin", "linh", "mei",
        "minh", "nari", "ping", "qi", "ren", "rina", "sakura", "seojun", "seo", "shan", "sora",
        "sun", "tao", "thanh", "wei", "wen", "xiaoming", "xiuying", "yan", "ying", "yuki", "yuna",
        "ming", "ling", "xing", "bing", "qing",
        "yusuke", "zhang",

        // Middle Eastern / North African
        "abdullah", "adel", "ahmad", "ahmed", "aisha", "ali", "amina", "amir", "ayesha", "dalia",
        "farah", "fatima", "hassan", "hussein", "ibrahim", "jamal", "karim", "khalid", "layla",
        "leila", "mariam", "mohammed", "mustafa", "nadia", "nour", "omar", "rania", "reza",
        "salma", "samir", "sara", "tariq", "yara", "yasmin", "youssef", "zahra", "zara",

        // Sub-Saharan African
        "abebe", "adaeze", "amara", "ayo", "bongani", "chidi", "chiamaka", "ekene", "emeka",
        "folake", "kwabena", "kwame", "lerato", "mandla", "nala", "ngozi", "nkechi", "obi",
        "olusegun", "oluwaseun", "sipho", "tendai", "thabo", "thandiwe", "yaw", "zanele",

        // Hebrew / Jewish
        "aviva", "chaim", "dov", "eitan", "hannah", "ilan", "leah", "miriam", "moshe", "noa",
        "rivka", "shira", "tamar", "yael", "yonatan",

        // Latin American / Iberian additional
        "alejandro", "beatriz", "camilo", "diego", "eduardo", "gabriela", "ignacio", "isabela",
        "joaquin", "leonardo", "manuela", "mariana", "matias", "renata", "santiago", "valeria",
        "xiomara"
    ]
}

/// Common English words that must never pass as a personal name.
///
/// Broader than `NameDenylist`: the denylist is the curated, reviewable artefact the team edits
/// during calibration, while this is the portable validator's own crude stand-in for the
/// part-of-speech knowledge `NLTagger` has and Linux does not. Any word here that is also a real
/// given name is intentionally absent — `GivenNameLexicon` is consulted first, so "may", "will" and
/// "mark" are handled by the denylist's `ambiguous` tier instead of being killed here.
public enum CommonWordLexicon {

    public static func contains(_ normalizedToken: String) -> Bool {
        words.contains(normalizedToken)
    }

    static let words: Set<String> = [
        // determiners, pronouns, prepositions, conjunctions
        "a", "an", "the", "this", "that", "these", "those", "i", "im", "ive", "you", "youre",
        "your", "he", "him", "his", "she", "her", "hers", "it", "its", "we", "were", "our", "us",
        "they", "them", "their", "theyre", "who", "whom", "whose", "which", "what", "where",
        "when", "why", "how", "and", "or", "but", "so", "if", "then", "than", "as", "at", "by",
        "for", "from", "in", "into", "of", "off", "on", "onto", "out", "over", "to", "too", "up",
        "with", "without", "about", "after", "before", "again", "also", "any", "both", "each",
        "few", "more", "most", "much", "many", "other", "some", "such", "only", "own", "same",
        "very", "just", "not", "nor", "because", "while", "during", "between", "through",
        "against", "around", "under", "above", "down", "back", "here", "there", "everywhere",

        // auxiliaries and very common verbs
        "am", "is", "are", "was", "wasnt", "werent", "be", "been", "being", "do", "does",
        "did", "doing", "done", "have", "has", "had", "having", "can", "cant", "could", "would",
        "should", "shall", "must", "might", "get", "got", "getting", "go", "going", "went",
        "gone", "come", "came", "coming", "see", "saw", "seen", "seeing", "meet", "meeting",
        "met", "know", "knew", "known", "think", "thought", "say", "said", "saying", "tell",
        "told", "talk", "talking", "talked", "speak", "spoke", "speaking", "give", "gave",
        "given", "take", "took", "taken", "taking", "make", "made", "making", "want", "wanted",
        "need", "needed", "like", "liked", "look", "looking", "looked", "work", "working",
        "worked", "call", "called", "calling", "help", "helping", "helped", "let", "lets",
        "put", "keep", "find", "found", "feel", "felt", "leave", "leaving", "left", "stay",
        "staying", "start", "started", "stop", "stopped", "wait", "waiting", "seem", "seems",

        // frequent nouns / adjectives / adverbs that can land in a name slot
        "time", "times", "day", "days", "week", "weeks", "month", "year", "years", "thing",
        "things", "people", "person", "guy", "girl", "boy", "woman", "man", "men", "women",
        "kid", "kids", "name", "names", "place", "way", "ways", "part", "point", "case", "fact",
        "hand", "side", "life", "world", "home", "house", "room", "office", "company", "job",
        "business", "money", "problem", "question", "answer", "idea", "story", "word", "words",
        "number", "group", "email", "phone", "coffee", "lunch", "dinner", "food",
        "water", "car", "road", "city", "town", "country", "school", "student", "teacher",
        "doctor", "everyone", "everybody", "anyone", "anybody", "someone", "somebody", "nobody",
        "everything", "anything", "something", "nothing", "today", "tomorrow", "yesterday",
        "tonight", "now", "later", "soon", "early", "late", "always", "never", "often",
        "sometimes", "usually", "already", "still", "yet", "ever", "well", "better", "best",
        "worse", "worst", "big", "small", "long", "short", "high", "low", "old", "young", "new",
        "next", "last", "first", "second", "third", "final", "different", "important",
        "sure", "ready", "fine", "okay", "true", "false", "real", "right", "wrong",
        "hard", "easy", "free", "busy", "happy", "glad", "sad", "sorry", "please", "thanks",
        "thank", "welcome", "hello", "hi", "hey", "bye", "goodbye", "yes", "yeah", "yep", "no",
        "nope", "maybe", "together", "alone", "friend", "friends", "team",
        "teams", "family", "folks", "guys", "all", "great", "good", "nice", "cool", "awesome",
        "amazing", "terrible", "morning", "afternoon", "evening", "night", "care", "dude",
        "buddy", "pal", "mate", "sir", "maam", "madam", "boss", "honey", "sweetie", "dear",
        "love", "lot", "lots", "bit", "kind", "sort", "type", "stuff", "yall", "alright",
        "actually", "really", "definitely", "probably", "certainly", "exactly", "totally",
        "seriously", "honestly", "basically", "literally", "obviously", "anyway", "however",
        "though", "although", "unless", "until", "since", "once", "twice",

        // frequent adverbs and adjectives that survive the morphology guard
        "perhaps", "instead", "besides", "otherwise", "meanwhile", "therefore", "indeed",
        "sometime", "somewhere", "anywhere", "nowhere", "everywhere", "earlier", "recently",
        "pretty", "quite", "super", "fantastic", "wonderful", "lovely", "excited", "tired",
        "hungry", "welcome", "afraid", "certain", "possible", "impossible"
    ]
}
