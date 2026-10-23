// Harvard resume (polish P5, set to Harvard's own guides in P5b), the template builds use.
// Everything comes from JSON (`--input data=<file>`, SPEC §5.6): Kairos never writes Typst
// source, so nothing in a resume is ever read as markup.
//
// From Harvard's Mignone Center: "a common, easy to read font", no text boxes, colour or shading,
// one size "kept consistent throughout", and equal margins of at least ¾ in (Master's guide, 2025).
// The layout follows its tech sample: name in bold capitals, one contact line, headings in bold
// capitals over a rule, then each entry as organization and place, then title and dates. Type is
// Liberation Serif, metric-compatible with the Times New Roman of Harvard's own sample.
//
// Which sections appear, their order, the dates' wording and the contact order are decided in
// Swift (`ResumeDocument(_:for:)`); this file only lays them out.

#let data = json(sys.inputs.at("data"))
#let settings = data.at("style", default: (:))
#let size = settings.at("fontSize", default: 11) * 1pt
#let opt(dict, key) = dict.at(key, default: none)
#let margin = settings.at("margin", default: 0.75) * 1in

#set document(title: data.header.name + ", resume")
#set page(paper: settings.at("paper", default: "us-letter"), margin: margin)
#set text(font: "Liberation Serif", size: size, lang: "en")
#set par(leading: 0.4em, spacing: 0.5em)
#set list(indent: 0.15in, body-indent: 0.12in, spacing: 0.4em, marker: [•])

// What the page fitter reads (`typst eval` of `query(<kairos-layout>)`): the lines each bullet takes
// at the list's width, its width set on one line, and where the document ends. It draws nothing.
#context {
  let column = page.width - 2 * margin - list.indent - list.body-indent - measure([•]).width
  let one = measure(block(width: column, [A])).height
  let step = measure(block(width: column, [A #linebreak() A])).height - one
  let bullets = ()
  for section in data.sections.filter(section => section.at("visible", default: true)) {
    for (item, entry) in section.at("items", default: ()).enumerate() {
      for (index, bullet) in entry.at("bullets", default: ()).enumerate() {
        let lines = int(calc.round((measure(block(width: column, bullet)).height - one) / step)) + 1
        bullets.push((
          section: section.kind, item: item, bullet: index, lines: lines, width: measure(bullet).width / 1pt,
          characters: bullet.clusters().len(),
        ))
      }
    }
  }
  let end = locate(<kairos-end>).position()
  [#metadata((
    column: column / 1pt, step: step / 1pt, top: margin / 1pt, bottom: (page.height - margin) / 1pt,
    end: (page: end.page, y: end.y / 1pt), bullets: bullets,
  ))<kairos-layout>]
}

// Header: the contact block, set by code, never by the model. One size, like everything else.
#align(center, {
  text(weight: "bold", upper(data.header.name))
  let headline = opt(data.header, "headline")
  if headline != none {
    linebreak()
    headline
  }
  let contact = data.header.at("contact", default: ())
  if contact.len() > 0 {
    linebreak()
    let items = contact.map(item => {
      let url = opt(item, "url")
      box(if url != none { link(url, item.text) } else { item.text })
    })
    items.join([ | ])
  }
})

#let section-label(title) = block(above: 1.1em, below: 0.5em, stack(
  spacing: 2.5pt,
  text(weight: "bold", upper(title)),
  line(length: 100%, stroke: 0.5pt),
))

// Left text and right text on one line, the right one flush with the margin.
#let row(left, right) = grid(columns: (1fr, auto), column-gutter: 1em, left, if right != none { right } else { [] })

// Organization and place, then title and dates (education: school and place, then degree and
// graduation). A project is one line, "Name | stack", with its dates.
#let entry(kind, item) = block(above: 0.8em, below: 0.3em, {
  let organization = opt(item, "subtitle")
  if kind == "projects" {
    let head = text(weight: "bold", item.title)
    if organization != none { head = head + [ | ] + emph(organization) }
    row(head, opt(item, "dates"))
  } else if organization != none {
    row(text(weight: "bold", organization), opt(item, "location"))
    v(0.5em, weak: true)
    row(if kind == "experience" { emph(item.title) } else { item.title }, opt(item, "dates"))
  } else {
    row(if kind == "certifications" { item.title } else { text(weight: "bold", item.title) }, opt(item, "dates"))
  }
  let bullets = item.at("bullets", default: ())
  if bullets.len() > 0 { block(above: 0.45em, list(..bullets)) }
})

#for section in data.sections.filter(section => section.at("visible", default: true)) {
  section-label(section.title)
  let paragraph = opt(section, "text")
  if paragraph != none { block(above: 0.4em, paragraph) }
  for item in section.at("items", default: ()) { entry(section.kind, item) }
  for group in section.at("groups", default: ()) {
    block(above: 0.35em, below: 0.35em, [#text(weight: "bold", group.label + ":") #group.items.join(", ")])
  }
}

// Where the document ends, for the measurement above.
#metadata(none)<kairos-end>
