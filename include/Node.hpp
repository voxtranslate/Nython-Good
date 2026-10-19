#ifndef __NODE__HPP
#define __NODE__HPP

#include <memory>
#include "INode.hpp"
#include "Except.hpp"
#include "Visitor.hpp"

namespace nython::node {

struct Node;
struct Script;

/// using node_ptr = std::shared_ptr<Node>;

#if defined(__GNUC__) && !defined(__clang__)
  #pragma GCC diagnostic push
  #pragma GCC diagnostic ignored "-Wnon-virtual-dtor"
#endif
struct Node extends INode, public std::enable_shared_from_this<Node> {

    NodeType _type;
    // round 86: 1 when the node is Python-language source's (a .py file, a
    // file marked `# nython: python`, code compiled from one, a function
    // that opts in): NyScope marks every node it walks under Python's rule,
    // and both engines take CPython's path for it where Nython is lenient
    // (str + non-str, an int iterated, `x is int`, a dict's keys read as
    // attributes). In what was padding: no node grows.
    uint8_t  py_src = 0;
    Token    _token;
	static Script* root;

    Node(NodeType type): _type{type},_token{} {
    }

    Node(Token t,NodeType type): _type{type},_token{t} {
    }

    virtual ~Node(){
    }

    // final (round 81): no node overrides them, and a call through a Node
    // pointer is then a field read instead of a virtual call.
    NodeType type() final {
    	return _type;
    }

	Token token() final {
		return _token;
	}
	// The token without copying it (round 81): token() returns a copy, two
	// strings and all, which the interpreter made on hot paths.
	const Token& tok() const { return _token; }

	virtual node_ptr get(int index){
    	if(index>=int(statements().size())) exception::IndexOutOfRangeError(location(), utils::format("The index you have provided is out of range: maximun value should be ", size()-1));
		return statements()[index];
    }

	virtual void set(int index,node_ptr node){
	}

	virtual Node* add(node_ptr){
		return this;
	}

	virtual bool empty(){
		return statements().empty();
	}

	/**
     * Returns all the statement content in this node.
     *
     * @return std::vector<node_ptr>.
	*/
    virtual std::vector<node_ptr> statements(){
		return {};
    }

    virtual int size(){
		return statements().size();
    }


    virtual Value eval(Context* context) {
		return NONE_VALUE;
    }

    virtual void accept(IVisitor* visitor){
		visitor->visit(this);
    }

    /**
     * @inheritDoc
    */
    void writeToStdOut(PrettyPrinter p){
		p.printf("<Node line=\"%d\" column=\"%d\"></Node>\n", token().line(), token().column());
    }

    /**
     * @inheritDoc
    */
    std::string toString(PrettyPrinter p){
    	std::string str;
    	p.printf(&str,"<Node line=\"%d\" column=\"%d\"></Node>\n", token().line(), token().column());
    	return str;
    }

    virtual bool isLitteral(){
    	switch(_type){
    		case NodeType::MAP:
    		case NodeType::NONE:
			case NodeType::TRUE:
			case NodeType::LIST:
			case NodeType::FALSE:
    		case NodeType::FLOAT:
			case NodeType::ARRAY:
			case NodeType::TUPLE:
			case NodeType::SUPER:
			case NodeType::STRING:
			case NodeType::COMPLEX:
			case NodeType::INTEGER:
			case NodeType::UNDEFINED:
			return true;
			default:
			return false;
    	}
    	return false;
    }

};
#if defined(__GNUC__) && !defined(__clang__)
  #pragma GCC diagnostic pop
#endif

}

#endif //__NODE__HPP
