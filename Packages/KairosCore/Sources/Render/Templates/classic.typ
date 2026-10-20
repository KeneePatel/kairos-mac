// Classic resume (T32). Everything comes from JSON (`--input data=<file>`, SPEC §5.6): Kairos
// never writes Typst source, so nothing in a resume is ever read as markup.
// Type: Source Serif 4, name 22pt, body 10.5/14, section labels 9.5pt caps (design README, Type).

#let data = json(sys.inputs.at("data"))
#let settings = data.at("style", default: (:))
#let body-size = settings.at("fontSize", default: 10.5) * 1pt
#let opt(dict, key) = dict.at(key, default: none)

#set document(title: data.header.name + ", resume")
#set page(paper: settings.at("paper", default: "us-letter"), margin: settings.at("margin", default: 0.6) * 1in)
#set text(font: "Source Serif 4", size: body-size, lang: "en")
#set par(leading: 0.42em, spacing: 0.6em)
#set list(indent: 0.4em, body-indent: 0.5em, spacing: 0.4em, marker: [•])

// Header: the contact block, set by code, never by the model.
#align(center, {
  text(size: 22pt, weight: "bold", data.header.name)
  let headline = opt(data.header, "headline")
  if headline != none {
    linebreak()
    text(size: body-size + 0.5pt, headline)
  }
  let contact = data.header.at("contact", default: ())
  if contact.len() > 0 {
    linebreak()
    let items = contact.map(item => {
      let url = opt(item, "url")
      if url != none { link(url, item.text) } else { item.text }
    })
    text(size: body-size - 1pt, items.join([ · ]))
  }
})

#let section-label(title) = block(above: 1.1em, below: 0.5em, stack(
  spacing: 3pt,
  text(size: 9.5pt, weight: "semibold", tracking: 0.06em, upper(title)),
  line(length: 100%, stroke: 0.4pt),
))

// "Title · Employer, City" on the left and the dates on the right, as `Build.dc.html` draws it.
#let entry(item) = block(above: 0.7em, below: 0.3em, {
  let dates = opt(item, "dates")
  let place = (opt(item, "subtitle"), opt(item, "location")).filter(part => part != none)
  let heading = text(weight: "semibold", item.title)
  if place.len() > 0 { heading = heading + [ · ] + place.join(", ") }
  grid(
    columns: (1fr, auto),
    column-gutter: 1em,
    heading,
    if dates != none { text(size: body-size - 0.5pt, dates) } else { [] },
  )
  let bullets = item.at("bullets", default: ())
  if bullets.len() > 0 { block(above: 0.4em, list(..bullets)) }
})

#for section in data.sections.filter(section => section.at("visible", default: true)) {
  section-label(section.title)
  let paragraph = opt(section, "text")
  if paragraph != none { block(above: 0.4em, paragraph) }
  for item in section.at("items", default: ()) { entry(item) }
  for group in section.at("groups", default: ()) {
    block(above: 0.35em, below: 0.35em, [#text(weight: "semibold", group.label + ":") #group.items.join(", ")])
  }
}
