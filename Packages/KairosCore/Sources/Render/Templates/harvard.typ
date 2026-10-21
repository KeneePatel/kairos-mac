// Harvard resume (polish P5), the template builds use. Everything comes from JSON (`--input
// data=<file>`, SPEC §5.6): Kairos never writes Typst source, so nothing in a resume is ever read as
// markup.
//
// Harvard's layout: centred name, section headings over a full-width rule, and two-line entries,
// bold title and dates on the first line, italic organization and place on the second. One body
// size throughout, as Harvard's guide asks. Type is New Computer Modern, built into typst, with
// real small caps for the name and headings (their text stays as typed, so parsers read
// "Experience", not "EXPERIENCE"). Contact links are underlined and led by an icon.
//
// Icons: Bootstrap Icons 1.13.2 (MIT, see ICONS.md). They're drawings, not characters, so the
// PDF's text has no stray symbols for an applicant tracking system to misread, and they're marked
// as decoration so screen readers skip them.

#let data = json(sys.inputs.at("data"))
#let settings = data.at("style", default: (:))
#let body-size = settings.at("fontSize", default: 10) * 1pt
#let opt(dict, key) = dict.at(key, default: none)

#set document(title: data.header.name + ", resume")
#set page(paper: settings.at("paper", default: "us-letter"), margin: settings.at("margin", default: 0.6) * 1in)
#set text(font: "New Computer Modern", size: body-size, lang: "en")
#set par(leading: 0.45em, spacing: 0.55em)
#set list(indent: 0.8em, body-indent: 0.5em, spacing: 0.34em, marker: text(size: 0.7em, baseline: -0.12em)[•])

#let icons = (
  email: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path d='M.05 3.555A2 2 0 0 1 2 2h12a2 2 0 0 1 1.95 1.555L8 8.414zM0 4.697v7.104l5.803-3.558zM6.761 8.83l-6.57 4.027A2 2 0 0 0 2 14h12a2 2 0 0 0 1.808-1.144l-6.57-4.027L8 9.586zm3.436-.586L16 11.801V4.697z'/> </svg>",
  phone: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path fill-rule='evenodd' d='M1.885.511a1.745 1.745 0 0 1 2.61.163L6.29 2.98c.329.423.445.974.315 1.494l-.547 2.19a.68.68 0 0 0 .178.643l2.457 2.457a.68.68 0 0 0 .644.178l2.189-.547a1.75 1.75 0 0 1 1.494.315l2.306 1.794c.829.645.905 1.87.163 2.611l-1.034 1.034c-.74.74-1.846 1.065-2.877.702a18.6 18.6 0 0 1-7.01-4.42 18.6 18.6 0 0 1-4.42-7.009c-.362-1.03-.037-2.137.703-2.877z'/> </svg>",
  linkedin: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path d='M0 1.146C0 .513.526 0 1.175 0h13.65C15.474 0 16 .513 16 1.146v13.708c0 .633-.526 1.146-1.175 1.146H1.175C.526 16 0 15.487 0 14.854zm4.943 12.248V6.169H2.542v7.225zm-1.2-8.212c.837 0 1.358-.554 1.358-1.248-.015-.709-.52-1.248-1.342-1.248S2.4 3.226 2.4 3.934c0 .694.521 1.248 1.327 1.248zm4.908 8.212V9.359c0-.216.016-.432.08-.586.173-.431.568-.878 1.232-.878.869 0 1.216.662 1.216 1.634v3.865h2.401V9.25c0-2.22-1.184-3.252-2.764-3.252-1.274 0-1.845.7-2.165 1.193v.025h-.016l.016-.025V6.169h-2.4c.03.678 0 7.225 0 7.225z'/> </svg>",
  github: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path d='M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8'/> </svg>",
  website: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path d='M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8m7.5-6.923c-.67.204-1.335.82-1.887 1.855q-.215.403-.395.872c.705.157 1.472.257 2.282.287zM4.249 3.539q.214-.577.481-1.078a7 7 0 0 1 .597-.933A7 7 0 0 0 3.051 3.05q.544.277 1.198.49zM3.509 7.5c.036-1.07.188-2.087.436-3.008a9 9 0 0 1-1.565-.667A6.96 6.96 0 0 0 1.018 7.5zm1.4-2.741a12.3 12.3 0 0 0-.4 2.741H7.5V5.091c-.91-.03-1.783-.145-2.591-.332M8.5 5.09V7.5h2.99a12.3 12.3 0 0 0-.399-2.741c-.808.187-1.681.301-2.591.332zM4.51 8.5c.035.987.176 1.914.399 2.741A13.6 13.6 0 0 1 7.5 10.91V8.5zm3.99 0v2.409c.91.03 1.783.145 2.591.332.223-.827.364-1.754.4-2.741zm-3.282 3.696q.18.469.395.872c.552 1.035 1.218 1.65 1.887 1.855V11.91c-.81.03-1.577.13-2.282.287zm.11 2.276a7 7 0 0 1-.598-.933 9 9 0 0 1-.481-1.079 8.4 8.4 0 0 0-1.198.49 7 7 0 0 0 2.276 1.522zm-1.383-2.964A13.4 13.4 0 0 1 3.508 8.5h-2.49a6.96 6.96 0 0 0 1.362 3.675c.47-.258.995-.482 1.565-.667m6.728 2.964a7 7 0 0 0 2.275-1.521 8.4 8.4 0 0 0-1.197-.49 9 9 0 0 1-.481 1.078 7 7 0 0 1-.597.933M8.5 11.909v3.014c.67-.204 1.335-.82 1.887-1.855q.216-.403.395-.872A12.6 12.6 0 0 0 8.5 11.91zm3.555-.401c.57.185 1.095.409 1.565.667A6.96 6.96 0 0 0 14.982 8.5h-2.49a13.4 13.4 0 0 1-.437 3.008M14.982 7.5a6.96 6.96 0 0 0-1.362-3.675c-.47.258-.995.482-1.565.667.248.92.4 1.938.437 3.008zM11.27 2.461q.266.502.482 1.078a8.4 8.4 0 0 0 1.196-.49 7 7 0 0 0-2.275-1.52c.218.283.418.597.597.932m-.488 1.343a8 8 0 0 0-.395-.872C9.835 1.897 9.17 1.282 8.5 1.077V4.09c.81-.03 1.577-.13 2.282-.287z'/> </svg>",
  location: "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='#000000' viewBox='0 0 16 16'> <path d='M8 16s6-5.686 6-10A6 6 0 0 0 2 6c0 4.314 6 10 6 10m0-7a3 3 0 1 1 0-6 3 3 0 0 1 0 6'/> </svg>",
)

#let icon(kind) = {
  let svg = icons.at(kind, default: none)
  if svg != none {
    pdf.artifact(kind: "layout", box(baseline: 0.13em, image(bytes(svg), format: "svg", height: 0.82em)))
    h(0.3em)
  }
}

#let contact-item(item) = {
  let url = opt(item, "url")
  let label = if url != none { link(url, underline(offset: 1.6pt, stroke: 0.45pt, item.text)) } else { item.text }
  box(icon(opt(item, "kind")) + label)
}

// Header: the contact block, set by code, never by the model. The place gets its own line, the
// way the reference lays it out, so the links fit on one.
#align(center, {
  text(size: 22pt, smallcaps(data.header.name))
  let headline = opt(data.header, "headline")
  if headline != none {
    linebreak()
    text(size: body-size + 0.5pt, headline)
  }
  let contact = data.header.at("contact", default: ())
  let places = contact.filter(item => opt(item, "kind") == "location")
  let rest = contact.filter(item => opt(item, "kind") != "location")
  for place in places {
    linebreak()
    contact-item(place)
  }
  if rest.len() > 0 {
    linebreak()
    rest.map(contact-item).join(h(1.1em))
  }
})

#let section-label(title) = block(above: 1.1em, below: 0.5em, stack(
  spacing: 3pt,
  text(size: body-size + 1.5pt, smallcaps(title)),
  line(length: 100%, stroke: 0.5pt),
))

// Left text and right text on one line, the right one flush with the margin.
#let row(left, right) = grid(columns: (1fr, auto), column-gutter: 1em, left, if right != none { right } else { [] })

// A project reads "Name | stack" with its dates; everything else takes two lines.
#let entry(kind, item) = block(above: 0.75em, below: 0.3em, {
  let subtitle = opt(item, "subtitle")
  let location = opt(item, "location")
  if kind == "projects" {
    let head = text(weight: "bold", item.title)
    if subtitle != none { head = head + [ | ] + emph(subtitle) }
    row(head, opt(item, "dates"))
  } else {
    row(text(weight: "bold", item.title), opt(item, "dates"))
    if subtitle != none or location != none {
      v(0.42em, weak: true)
      row(emph(if subtitle != none { subtitle } else { [] }), if location != none { emph(location) })
    }
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
    block(above: 0.32em, below: 0.32em, [#text(weight: "bold", group.label): #group.items.join(", ")])
  }
}
