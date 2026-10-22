import Foundation
import Testing
@testable import XBloomCore

@Test func recipeFoldersUseBagIdentityAndPreserveUnlinkedAndMissingBeans() {
    let first = BeanProfile(name: "Guji")
    let second = BeanProfile(name: "Guji")
    var linked = RecipeLibrary.defaults[0]; linked.beanID = first.id
    var hot = linked; hot.id = UUID(); hot.beanID = nil; hot.brewStyle = .hot
    var iced = hot; iced.id = UUID(); iced.brewStyle = .iced
    var orphan = linked; orphan.id = UUID(); orphan.beanID = UUID()
    let folders = RecipeFolders.make(beans: [first, second], recipes: [linked, hot, iced, orphan])
    #expect(folders.count == 5)
    #expect(folders.first { $0.id == .bean(first.id) }?.recipeIDs == [linked.id])
    #expect(folders.first { $0.id == .bean(second.id) }?.recipeIDs.isEmpty == true)
    #expect(folders.first { $0.id == .generalHot }?.recipeIDs == [hot.id])
    #expect(folders.first { $0.id == .generalIced }?.recipeIDs == [iced.id])
    #expect(folders.first { $0.id == .unavailableBeans }?.recipeIDs == [orphan.id])
    #expect(RecipeFolders.make(beans: [first, second], recipes: [], includeEmptyBeans: false).isEmpty)
}

@Test func archivedBagsRetainTheirRecipesButDoNotCreateEmptyFolders() {
    let bean = BeanProfile(name: "Archived", archived: true)
    var recipe = RecipeLibrary.defaults[0]; recipe.beanID = bean.id
    #expect(RecipeFolders.make(beans: [bean], recipes: []).isEmpty)
    #expect(RecipeFolders.make(beans: [bean], recipes: [recipe]).first?.id == .bean(bean.id))
}

@Test func brewTargetUsesCalendarDaysAndDoesNotInventUnknownOrFutureDates() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let roast = calendar.date(byAdding: .day, value: -25, to: now)!
    #expect(BeanBrewWindow(roastDate: roast, targetDays: 30, now: now, calendar: calendar).daysRemaining == 5)
    #expect(BeanBrewWindow(roastDate: roast, targetDays: 21, now: now, calendar: calendar).daysRemaining == -4)
    #expect(BeanBrewWindow(roastDate: nil, targetDays: 30, now: now).daysRemaining == nil)
    #expect(BeanBrewWindow(roastDate: now.addingTimeInterval(86_400), targetDays: 30, now: now, calendar: calendar).daysRemaining == nil)
}

@Test func brewSuggestionHonorsStockWindowAndArchiveStatus() {
    let now = Date()
    let older = BeanProfile(name: "Use first", roastDate: now.addingTimeInterval(-25 * 86_400), remainingWeightGrams: 20)
    let newer = BeanProfile(name: "Newer", roastDate: now.addingTimeInterval(-10 * 86_400))
    var first = RecipeLibrary.defaults[0]; first.beanID = older.id; first.dose = 18
    var second = first; second.id = UUID(); second.beanID = newer.id
    let suggestion = BeanBrewSuggestion.next(beans: [newer, older], recipes: [second, first], targetDays: 30, now: now)
    #expect(suggestion?.beanID == older.id)
    var empty = older; empty.remainingWeightGrams = 17
    #expect(BeanBrewSuggestion.next(beans: [empty], recipes: [first], targetDays: 30, now: now) == nil)
    var archived = older; archived.archived = true
    #expect(BeanBrewSuggestion.next(beans: [archived], recipes: [first], targetDays: 30, now: now) == nil)
    #expect(BeanBrewSuggestion.next(beans: [older], recipes: [first], targetDays: 14, now: now) == nil)
    first.dose = .nan
    #expect(BeanBrewSuggestion.next(beans: [older], recipes: [first], targetDays: 30, now: now) == nil)
}
