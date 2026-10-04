import SwiftUI
import UIKit

/// Source mark for a rating (IMDb, Rotten Tomatoes, ...). If you add an image to Assets.xcassets
/// with one of the names below, it is used instead of the drawn mark:
/// logo-imdb, logo-tmdb, logo-rt, logo-rt-audience, logo-metacritic, logo-letterboxd, logo-trakt
struct RatingLogo: View {
    let label: String
    var value: String = ""
    var height: CGFloat = 20

    private static let assets = [
        "IMDb": "logo-imdb", "TMDB": "logo-tmdb", "Rotten Tomatoes": "logo-rt",
        "RT Audience": "logo-rt-audience", "Metacritic": "logo-metacritic",
        "Letterboxd": "logo-letterboxd", "Trakt": "logo-trakt",
    ]

    var body: some View {
        if let name = Self.assets[label], UIImage(named: name) != nil {
            Image(name).resizable().scaledToFit().frame(height: height)
        } else {
            drawn
        }
    }

    private var fresh: Bool { (Int(value.filter { $0.isNumber }) ?? 100) >= 60 }

    @ViewBuilder private var drawn: some View {
        switch label {
        case "IMDb":
            Text("IMDb")
                .font(.system(size: height * 0.62, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 5).frame(height: height)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case "TMDB":
            Text("TMDB")
                .font(.system(size: height * 0.58, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.56, green: 0.81, blue: 0.63), Color(red: 0.0, green: 0.71, blue: 0.89)],
                    startPoint: .leading, endPoint: .trailing))
                .padding(.horizontal, 5).frame(height: height)
                .background(Color(red: 0.04, green: 0.145, blue: 0.247), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case "Rotten Tomatoes":
            ZStack {
                Circle().fill(fresh ? Color(red: 0.98, green: 0.19, blue: 0.08) : Color(red: 0.42, green: 0.72, blue: 0.2))
                    .frame(width: height * 0.9, height: height * 0.9).offset(y: height * 0.06)
                if fresh {
                    Capsule().fill(Color(red: 0.2, green: 0.62, blue: 0.2))
                        .frame(width: height * 0.38, height: height * 0.2).offset(y: -height * 0.4)
                }
            }
            .frame(width: height, height: height)
        case "RT Audience":
            Image(systemName: "popcorn.fill")
                .font(.system(size: height * 0.85))
                .foregroundStyle(fresh ? Color(red: 0.98, green: 0.19, blue: 0.08) : Color(red: 0.42, green: 0.72, blue: 0.2))
                .frame(height: height)
        case "Metacritic":
            Text("M")
                .font(.system(size: height * 0.7, weight: .heavy, design: .serif))
                .foregroundStyle(.white)
                .frame(width: height, height: height)
                .background(.black, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        case "Letterboxd":
            HStack(spacing: -height * 0.16) {
                Circle().fill(Color(red: 1.0, green: 0.5, blue: 0.0))
                Circle().fill(Color(red: 0.0, green: 0.88, blue: 0.33))
                Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96))
            }
            .frame(width: height * 1.5, height: height * 0.62)
        case "Trakt":
            ZStack {
                Circle().fill(Color(red: 0.93, green: 0.11, blue: 0.14))
                Image(systemName: "checkmark").font(.system(size: height * 0.5, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: height, height: height)
        default:
            Text(label).font(.caption2.bold())
        }
    }
}
