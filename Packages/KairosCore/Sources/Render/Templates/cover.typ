// Cover letter (T38). Everything comes from JSON (`--input data=<file>`, SPEC §5.6): Kairos never
// writes Typst source, so nothing in a letter is ever read as markup. The header matches
// classic.typ: Source Serif 4, name 22pt, the contact line under it.

#let data = json(sys.inputs.at("data"))
#let settings = data.at("style", default: (:))
#let body-size = settings.at("fontSize", default: 11) * 1pt
#let opt(dict, key) = dict.at(key, default: none)

#set document(title: data.header.name + ", cover letter")
#set page(paper: settings.at("paper", default: "us-letter"), margin: settings.at("margin", default: 1) * 1in)
#set text(font: "Source Serif 4", size: body-size, lang: "en")
#set par(leading: 0.6em, spacing: 1.2em)

// Header: the contact block, set by code, never by the model.
#align(center, {
  text(size: 22pt, weight: "bold", data.header.name)
  let contact = data.header.at("contact", default: ())
  if contact.len() > 0 {
    linebreak()
    let items = contact.map(item => {
      let url = opt(item, "url")
      if url != none { link(url, item.text) } else { item.text }
    })
    text(size: body-size - 1.5pt, items.join([ · ]))
  }
})
#line(length: 100%, stroke: 0.4pt)

#block(above: 2em, data.date)
#block(above: 1.4em, data.recipient.join(linebreak()))
#let subject = opt(data, "subject")
#if subject != none { block(above: 1.4em, text(weight: "semibold", subject)) }
#block(above: 1.4em, data.greeting)
#for paragraph in data.paragraphs { block(above: 1.2em, paragraph) }
#block(above: 1.4em, data.closing)
#block(above: 2.6em, text(weight: "semibold", data.signature))
