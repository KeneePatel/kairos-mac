// Spike template (T06): proves a template can read its content as JSON.
// The real resume templates replace this in T32.
#let data = json(sys.inputs.at("data"))

#set page(paper: "us-letter", margin: 0.6in)
#set text(size: 10.5pt)

#align(center, text(size: 22pt, weight: "bold", data.name))

= Experience
#for bullet in data.bullets [
  - #bullet
]
