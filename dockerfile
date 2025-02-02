# ---------- Stage 1: Build the application ----------
    FROM node:18 AS builder

    # Set working directory
    WORKDIR /app
    
    # Copy dependency files first for better caching
    COPY package*.json tsconfig.json ./
    
    # Install all dependencies (including dev dependencies for building)
    RUN npm install
    
    # Copy all source files into the container
    COPY . .
    
    # Build the TypeScript code (ensure you have "build": "tsc" in package.json)
    RUN npm run build
    
    # ---------- Stage 2: Create the production image ----------
    FROM node:18-alpine
    
    # Set working directory
    WORKDIR /app
    
    # Copy the production build from the builder stage.
    # Assuming your compiled JavaScript is output to the "dist" directory.
    COPY --from=builder /app/dist ./dist
    COPY package*.json ./
    
    # Install only production dependencies (skip dev dependencies)
    RUN npm install --only=production
    
    # Set default environment variables (PORT defaults to 3000)
    ENV PORT=3000
    
    # Expose the port to be used by the container
    EXPOSE ${PORT}
    
    # Set the default command to run your app.
    # Make sure the entry point matches the output location (e.g., dist/index.js).
    CMD [ "node", "dist/index.js" ]
    