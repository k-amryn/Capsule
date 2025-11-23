from svglib.svglib import svg2rlg
from reportlab.graphics import renderPM
from PIL import Image
import io

# 1. Convert SVG to PNG using svglib/reportlab
drawing = svg2rlg("assets/capsule.svg")
# Scale up for high resolution (SVG is 26x44, let's make it 1024x1024 compatible)
# 1024 / 44 ~= 23.27. Let's scale by 20 to be safe and have padding.
scale_factor = 20
drawing.scale(scale_factor, scale_factor)
drawing.width *= scale_factor
drawing.height *= scale_factor

# Render to a BytesIO object
png_data = io.BytesIO()
renderPM.drawToFile(drawing, png_data, fmt="PNG")
png_data.seek(0)

# 2. Open the generated PNG with Pillow
icon_layer = Image.open(png_data).convert("RGBA")

# 3. Create the background
# macOS icons are typically 1024x1024
bg_size = (1024, 1024)
bg_color = (33, 33, 33, 255) # #212121
final_icon = Image.new("RGBA", bg_size, bg_color)

# 4. Center the icon on the background
# Calculate position to center
x_pos = (bg_size[0] - icon_layer.width) // 2
y_pos = (bg_size[1] - icon_layer.height) // 2

# Paste the icon using itself as a mask for transparency
final_icon.paste(icon_layer, (x_pos, y_pos), icon_layer)

# 5. Save the result
final_icon.save("assets/icon_bg.png")
print("Successfully created assets/icon_bg.png from SVG with grey background")