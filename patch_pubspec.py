with open('pubspec.yaml', 'r') as f:
    content = f.read()

content = content.replace("dependency_overrides:\n  camera_linux:", "dependency_overrides:\n  uuid: ^4.1.0\n  camera_linux:")

with open('pubspec.yaml', 'w') as f:
    f.write(content)
