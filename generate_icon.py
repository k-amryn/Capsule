from PIL import Image

# Open the original icon
icon = Image.open("assets/icon.png")

# Create a new image with the same size and a grey background
# Using #212121 which is the grey used in the app (Colors.grey[900] is roughly #212121)
bg_color = (33, 33, 33, 255) # #212121
new_icon = Image.new("RGBA", icon.size, bg_color)

# Paste the original icon on top
# Use the icon itself as the mask to preserve transparency if it has any
new_icon.paste(icon, (0, 0), icon)

# Save the new icon
new_icon.save("assets/icon_bg.png")
print("Successfully created assets/icon_bg.png with grey background")