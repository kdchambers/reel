
# Generic Vertex
glslangValidator -V generic.vert -o generic.vert.spv
glslangValidator -V generic.frag -o generic.frag.spv

# Texture Vertex
glslangValidator -V texture.vert -o texture.vert.spv
glslangValidator -V texture.frag -o texture.frag.spv

# Icon Vertex
glslangValidator -V icon.vert -o icon.vert.spv
glslangValidator -V icon.frag -o icon.frag.spv

# Color Vertex
glslangValidator -V color.vert -o color.vert.spv
glslangValidator -V color.frag -o color.frag.spv

echo 'Done'
